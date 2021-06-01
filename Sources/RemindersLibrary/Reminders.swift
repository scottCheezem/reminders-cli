import EventKit
import Foundation

public enum OutputFormat {
    case json, plainText
}

enum ReminderCodingKeys: String, CodingKey {
    case title
    case dueDateEpoch
    case dueDateHumanReadable
    case creationDate
}

extension EKReminder: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ReminderCodingKeys.self)
        try container.encode(self.title, forKey: ReminderCodingKeys.title)
        if let _ = self.dueDateComponents {
            try container.encode(formattedDueDate(from: self), forKey: ReminderCodingKeys.dueDateHumanReadable)
            try container.encode(formattedEpochTimer(from: self), forKey: ReminderCodingKeys.dueDateEpoch)
        }
        if let creationDate = self.creationDate {
            try container.encode(creationDate.timeIntervalSince1970, forKey: ReminderCodingKeys.creationDate)
        }
    }
}


private let Store = EKEventStore()
private let dateFormatter = RelativeDateTimeFormatter()
private func formattedDueDate(from reminder: EKReminder) -> String? {
    reminder.dueDateComponents?.date.map {
        dateFormatter.localizedString(for: $0, relativeTo: Date())
    }
}

private func formattedEpochTimer(from reminder: EKReminder) -> Int? {
    reminder.dueDateComponents?.date.map {
        Int($0.timeIntervalSince1970)
    }
}

private func format(_ reminder: EKReminder, at index: Int) -> String {
    let dateString = formattedDueDate(from: reminder).map { " (\($0))" } ?? ""
    return "\(index): \(reminder.title ?? "<unknown>")\(dateString)"
}

public final class Reminders {
    public static func requestAccess() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var grantedAccess = false
        Store.requestAccess(to: .reminder) { granted, _ in
            grantedAccess = granted
            semaphore.signal()
        }

        semaphore.wait()
        return grantedAccess
    }

    func showLists() {
        let calendars = self.getCalendars()
        for calendar in calendars {
            print(calendar.title)
        }
    }

    func showListItems(withNames names: [String], inFormat: OutputFormat = .plainText, dueDateOnly: Bool = false) {
        if let calendars = self.calendars(withNames: names) {
            let semaphore = DispatchSemaphore(value: 0)
                self.reminders(onCalendars: calendars) { reminders in
                    let filteredReminders = dueDateOnly ? reminders.filter{$0.dueDateComponents != nil} : reminders
                    if inFormat == .json,
                       let jsonData = try? JSONEncoder().encode(filteredReminders),
                       let jsonString = String(data: jsonData, encoding: String.Encoding.utf8) {
                        print(jsonString)
                    }
                    else  {
                        for (i, reminder) in filteredReminders.enumerated() {
                            print(format(reminder, at: i))
                        }
                    }
                    semaphore.signal()
                }
            semaphore.wait()
        }
    }

    func complete(itemAtIndex index: Int, onListNamed name: String) {
        let calendar = self.calendar(withName: name)
        let semaphore = DispatchSemaphore(value: 0)

        self.reminders(onCalendars: [calendar]) { reminders in
            guard let reminder = reminders[safe: index] else {
                print("No reminder at index \(index) on \(name)")
                exit(1)
            }

            do {
                reminder.isCompleted = true
                try Store.save(reminder, commit: true)
                print("Completed '\(reminder.title!)'")
            } catch let error {
                print("Failed to save reminder with error: \(error)")
                exit(1)
            }

            semaphore.signal()
        }

        semaphore.wait()
    }

    func addReminder(string: String, toListNamed name: String, dueDate: DateComponents?) {
        let calendar = self.calendar(withName: name)
        let reminder = EKReminder(eventStore: Store)
        reminder.calendar = calendar
        reminder.title = string
        reminder.dueDateComponents = dueDate

        do {
            try Store.save(reminder, commit: true)
            print("Added '\(reminder.title!)' to '\(calendar.title)'")
        } catch let error {
            print("Failed to save reminder with error: \(error)")
            exit(1)
        }
    }

    // MARK: - Private functions

    private func reminders(onCalendars calendars: [EKCalendar],
                                      completion: @escaping (_ reminders: [EKReminder]) -> Void)
    {
        let predicate = Store.predicateForReminders(in: calendars)
        Store.fetchReminders(matching: predicate) { reminders in
            let reminders = reminders?
                .filter { !$0.isCompleted }
            completion(reminders ?? [])
        }
    }

    private func calendar(withName name: String) -> EKCalendar {
        if let calendar = self.getCalendars().find(where: { $0.title.lowercased() == name.lowercased() }) {
            return calendar
        } else {
            print("No reminders list matching \(name)")
            exit(1)
        }
    }
    
    private func calendars(withNames names: [String]) -> [EKCalendar]? {
        let lowerCasedNames = names.map{ $0.lowercased() }
        if let calendars = try? self.getCalendars().filter({ lowerCasedNames.contains( $0.title.lowercased() )}) {
            return calendars
        }
    }

    private func getCalendars() -> [EKCalendar] {
        return Store.calendars(for: .reminder)
                    .filter { $0.allowsContentModifications }
    }
}
