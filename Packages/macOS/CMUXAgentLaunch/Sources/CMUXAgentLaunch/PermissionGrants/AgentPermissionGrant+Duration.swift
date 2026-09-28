public import Foundation

/// How long an approved grant lasts.
///
/// Grants always expire: the default is a day and the longest a request may
/// ask for is thirty days.
extension AgentPermissionGrant {
    /// The expiry used when a request doesn't name one: 24 hours.
    public static let defaultDurationSeconds: TimeInterval = 24 * 60 * 60
    /// The shortest expiry a request may ask for: one minute.
    public static let minimumDurationSeconds: TimeInterval = 60
    /// The longest expiry a request may ask for: 30 days.
    public static let maximumDurationSeconds: TimeInterval = 30 * 24 * 60 * 60

    /// Parses a duration such as `90`, `45s`, `30m`, `2h`, or `7d`.
    ///
    /// A bare number is seconds. Units are case-insensitive.
    /// - Returns: The duration in seconds, or `nil` when the text isn't a
    ///   positive whole number with an optional `s`, `m`, `h`, or `d` unit.
    public static func durationSeconds(from text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let last = trimmed.last else { return nil }
        let multiplier: TimeInterval
        let digits: Substring
        switch last {
        case "s": multiplier = 1; digits = trimmed.dropLast()
        case "m": multiplier = 60; digits = trimmed.dropLast()
        case "h": multiplier = 60 * 60; digits = trimmed.dropLast()
        case "d": multiplier = 24 * 60 * 60; digits = trimmed.dropLast()
        default: multiplier = 1; digits = Substring(trimmed)
        }
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let value = Int(digits), value > 0 else { return nil }
        return TimeInterval(value) * multiplier
    }
}
