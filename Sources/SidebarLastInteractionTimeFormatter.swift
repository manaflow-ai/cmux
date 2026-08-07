import Foundation

/// Formats the sidebar's relative "time since the last submitted prompt"
/// label (`sidebar.showLastInteractionInsteadOfPath`) and computes the
/// wall-clock date of the next label change so renderers can refresh
/// exactly when the label ticks instead of polling.
enum SidebarLastInteractionTimeFormatter {
    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 3600
    private static let day: TimeInterval = 86400

    /// Terse bucket label matching the sidebar's compact metadata tone:
    /// "now" under a minute, then "12m", "3h", "2d".
    static func label(from interactionDate: Date, to now: Date) -> String {
        let elapsed = now.timeIntervalSince(interactionDate)
        if elapsed < minute {
            return String(localized: "sidebar.lastInteraction.now", defaultValue: "now")
        }
        if elapsed < hour {
            let minutes = Int(elapsed / minute)
            return String(localized: "sidebar.lastInteraction.minutes", defaultValue: "\(minutes)m")
        }
        if elapsed < day {
            let hours = Int(elapsed / hour)
            return String(localized: "sidebar.lastInteraction.hours", defaultValue: "\(hours)h")
        }
        let days = Int(elapsed / day)
        return String(localized: "sidebar.lastInteraction.days", defaultValue: "\(days)d")
    }

    /// The earliest wall-clock date after `now` at which `label(from:to:)`
    /// can change. Always strictly later than `now` so a refresh timer never
    /// spins on a bucket boundary.
    static func nextTransitionDate(from interactionDate: Date, after now: Date) -> Date {
        let elapsed = now.timeIntervalSince(interactionDate)
        let stride: TimeInterval
        if elapsed < hour {
            stride = minute
        } else if elapsed < day {
            stride = hour
        } else {
            stride = day
        }
        let bucketsElapsed = max(0, (elapsed / stride).rounded(.down))
        let next = interactionDate.addingTimeInterval((bucketsElapsed + 1) * stride)
        return max(next, now.addingTimeInterval(1))
    }

    /// Absolute-time tooltip counterpart for the relative label. Includes
    /// seconds so two prompts submitted within the same minute (e.g. a
    /// copy-paste relay between sessions) can still be ordered.
    static func absoluteLabel(for interactionDate: Date) -> String {
        interactionDate.formatted(date: .abbreviated, time: .standard)
    }

    /// Short absolute-time row label for
    /// `sidebar.lastInteractionTimestampStyle == .absolute`: time-of-day
    /// only, with seconds, no date. Unlike `label(from:to:)` this never
    /// changes for a fixed interaction date, so renderers using this style
    /// need no refresh timer.
    static func absoluteShortLabel(for interactionDate: Date) -> String {
        interactionDate.formatted(date: .omitted, time: .standard)
    }
}
