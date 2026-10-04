import Foundation

/// How a ready update makes itself known (`updates.notify`).
nonisolated public enum UpdateNotifyMode: String, Sendable, CaseIterable {
    /// The quiet "Update ready" card above Settings, plus the Settings badge.
    case card
    /// Only the badge on the Settings item.
    case badge
    /// Nothing shows; the update installs on quit (or by `cmux update install`).
    case silent
}

/// A daily window, in minutes after local midnight, in which a ready update
/// does not show its card (`updates.quietHours`). `start == end` is empty;
/// `start > end` wraps past midnight (22:00-07:00).
nonisolated public struct UpdateQuietHours: Equatable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = Self.clamp(start)
        self.end = Self.clamp(end)
    }

    static func clamp(_ minute: Int) -> Int { ((minute % 1440) + 1440) % 1440 }

    /// Whether `minuteOfDay` falls inside the window.
    public func contains(minuteOfDay: Int) -> Bool {
        let m = Self.clamp(minuteOfDay)
        if start == end { return false }
        return start < end ? (m >= start && m < end) : (m >= start || m < end)
    }

    /// Minutes from `minuteOfDay` to the next start or end, for the one-shot
    /// timer that re-renders the card (never 0, at most 1440).
    public func minutesToNextBoundary(from minuteOfDay: Int) -> Int {
        let m = Self.clamp(minuteOfDay)
        func distance(_ target: Int) -> Int {
            let d = (target - m + 1440) % 1440
            return d == 0 ? 1440 : d
        }
        return min(distance(start), distance(end))
    }
}

/// The user's update settings the install gate and the card read
/// (`updates.*` in the shared settings schema).
nonisolated public struct UpdatePreferences: Equatable, Sendable {
    public var installOnQuit: Bool
    public var notify: UpdateNotifyMode
    public var quietHours: UpdateQuietHours?

    public init(installOnQuit: Bool = true, notify: UpdateNotifyMode = .card, quietHours: UpdateQuietHours? = nil) {
        self.installOnQuit = installOnQuit
        self.notify = notify
        self.quietHours = quietHours
    }

    public static let defaults = UpdatePreferences()
}
