public import Foundation

/// Groups notification values into calendar-day sections relative to an injected instant.
public struct NotificationFeedDayGrouping: Sendable {
    private let now: Date
    private let calendar: Calendar

    /// Creates a grouping policy.
    /// - Parameters:
    ///   - now: The instant treated as today.
    ///   - calendar: The calendar and time zone used for day boundaries.
    public init(now: Date, calendar: Calendar) {
        self.now = now
        self.calendar = calendar
    }

    /// Groups values by day while preserving their incoming order.
    /// - Parameters:
    ///   - items: Values to group, normally already newest first.
    ///   - createdAt: A projection returning each value's creation instant.
    /// - Returns: Sections in first-occurrence order.
    public func sections<Item>(
        for items: [Item],
        createdAt: (Item) -> Date
    ) -> [NotificationFeedDaySection<Item>] {
        var result: [NotificationFeedDaySection<Item>] = []
        for item in items {
            let day = day(containing: createdAt(item))
            if result.last?.day == day {
                let previous = result.removeLast()
                result.append(NotificationFeedDaySection(day: day, items: previous.items + [item]))
            } else {
                result.append(NotificationFeedDaySection(day: day, items: [item]))
            }
        }
        return result
    }

    private func day(containing date: Date) -> NotificationFeedDay {
        if calendar.isDate(date, inSameDayAs: now) {
            return .today
        }
        let today = calendar.startOfDay(for: now)
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        return .older(calendar.startOfDay(for: date))
    }
}
