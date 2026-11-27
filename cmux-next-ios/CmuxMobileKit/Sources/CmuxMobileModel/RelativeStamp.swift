import Foundation
import Synchronization

/// Compact relative times (SPEC 11.1 `meta`): "now", "4m", "3h", "2d", then
/// a short date. The one formatter for a Mac's "Last seen" on every surface
/// (Workspaces rows and filter, Settings → Devices). The surfaces pass the
/// shared `MinuteClock`'s `now`, so they all agree; the elapsed time itself is
/// exact ("1m" from 60 s, "2m" from 120 s).
public struct RelativeStamp: Sendable {
    public var now: Date
    public var calendar: Calendar

    public init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    /// What VoiceOver says for `date`, matching ``string(for:)``: "now" under a minute
    /// (also for a time a little ahead of the minute clock, which read "in 10 seconds",
    /// full verify D14), else "5 minutes ago".
    public func spoken(for date: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        // One formatter per calendar: a row's VoiceOver label made a new one per row per pass.
        let (now, calendar) = (now, calendar)
        return Self.formatters.withLock { formatters in
            if let formatter = formatters[calendar] { return formatter.localizedString(for: date, relativeTo: now) }
            let formatter = RelativeDateTimeFormatter()
            formatter.calendar = calendar
            formatters[calendar] = formatter
            return formatter.localizedString(for: date, relativeTo: now)
        }
    }

    private static let formatters = Mutex<[Calendar: RelativeDateTimeFormatter]>([:])

    public func string(for date: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
        default:
            var style = Date.FormatStyle(date: .numeric, time: .omitted)
            style.calendar = calendar
            return date.formatted(style)
        }
    }

    /// "Online", or "Last seen 2h ago" for an offline Mac.
    public func presence(isOnline: Bool, lastSeenAt: Date?) -> String {
        if isOnline { return "Online" }
        guard let lastSeenAt else { return "Offline" }
        let value = string(for: lastSeenAt)
        return value == "now" ? "Last seen just now" : (value.count <= 4 ? "Last seen \(value) ago" : "Last seen \(value)")
    }
}
