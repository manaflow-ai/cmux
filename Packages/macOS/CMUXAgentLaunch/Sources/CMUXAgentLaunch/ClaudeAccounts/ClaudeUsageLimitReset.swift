import Foundation

/// Parses the reset time out of Claude Code's usage-limit messages, for example
/// `You've hit your session limit · resets 6:50pm (Asia/Seoul)`,
/// `5-hour limit reached ∙ resets 3pm (America/New_York)` or
/// `You've hit your weekly limit · resets Oct 3 at 9am`.
public enum ClaudeUsageLimitReset {
    /// Used by callers when a limit message carries no parseable reset time.
    public static let fallbackInterval: TimeInterval = 5 * 3600

    private static let pattern =
        #"^(?:([A-Za-z]{3,9})\.?\s+(\d{1,2})\s+at\s+)?(\d{1,2})(?::(\d{2}))?\s*([ap]m)\b(?:\s*\(([^)]*)\))?"#

    /// Returns the next instant matching the message's reset time, or nil when none can be parsed.
    /// A zone in parentheses overrides `timeZone`; an unknown zone falls back to it.
    public static func resetDate(inMessage message: String, now: Date, timeZone: TimeZone) -> Date? {
        guard let marker = message.range(of: "resets ", options: .backwards) else { return nil }
        let tail = String(message[marker.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail))
        else { return nil }

        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: tail) else { return nil }
            return String(tail[range])
        }

        guard let hour12 = group(3).flatMap({ Int($0) }), (1...12).contains(hour12) else { return nil }
        let minute = group(4).flatMap { Int($0) } ?? 0
        guard (0...59).contains(minute) else { return nil }
        let isPM = group(5)?.lowercased() == "pm"
        let hour = (hour12 % 12) + (isPM ? 12 : 0)

        var zone = timeZone
        if let name = group(6)?.trimmingCharacters(in: .whitespaces), let parsed = TimeZone(identifier: name) {
            zone = parsed
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.dateComponents([.year, .month, .day], from: now)

        if let monthName = group(1), let dayText = group(2), let day = Int(dayText) {
            guard let month = month(named: monthName), let year = today.year else { return nil }
            func candidate(_ year: Int) -> Date? {
                let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
                guard let date = calendar.date(from: components) else { return nil }
                let check = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                guard check.month == month, check.day == day, check.hour == hour, check.minute == minute else { return nil }
                return date
            }
            guard let date = candidate(year) else { return nil }
            if date < now.addingTimeInterval(-86_400) { return candidate(year + 1) }
            return date
        }

        var components = today
        components.hour = hour
        components.minute = minute
        guard let date = calendar.date(from: components) else { return nil }
        if date <= now { return calendar.date(byAdding: .day, value: 1, to: date) }
        return date
    }

    private static func month(named name: String) -> Int? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let prefix = name.prefix(3).lowercased()
        guard let index = formatter.shortMonthSymbols.firstIndex(where: { $0.lowercased() == prefix }) else { return nil }
        return index + 1
    }
}
