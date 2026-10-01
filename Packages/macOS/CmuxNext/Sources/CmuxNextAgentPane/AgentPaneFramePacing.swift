import Foundation

/// How fast an agent pane renders.
public enum AgentPaneRenderRate: Sendable {
    /// WebKit's default: the display-rate divisor at or above 60 fps (80 Hz
    /// on a 160 Hz display).
    case capped
    /// The display's full rate.
    case full
    /// The full rate while scrolls keep up, capped while the machine is
    /// loaded (``AgentPaneFramePacing``).
    case adaptive
}

/// Chooses the agent pane's rendering rate from how its scrolls paced. The
/// pane renders at the display's full rate until a scroll misses too many
/// frames, then at WebKit's capped rate (the display-rate divisor at or
/// above 60 fps) while the machine is loaded. After a backoff, a capped
/// scroll that paces cleanly brings full rate back; the backoff doubles
/// when full rate fails again soon after.
nonisolated struct AgentPaneFramePacing: Equatable, Sendable {
    /// Scrolls shorter than this many frames decide nothing.
    static let minimumFrames = 30
    /// A frame is late when its interval exceeds the expected one by half.
    static let lateFactor = 1.5
    /// Late share at full rate that drops to the capped rate.
    static let overloaded = 0.2
    /// Late share at the capped rate below which full rate may come back.
    static let recovered = 0.05
    /// The first wait at the capped rate before full rate is tried again,
    /// and the longest.
    static let firstBackoff: TimeInterval = 10
    static let maximumBackoff: TimeInterval = 160

    private(set) var fullRate = true
    private var backoff = firstBackoff
    /// When the pane last changed rate.
    private var changedAt: Date?

    /// Records one scroll's frame intervals (ms) on a display that refreshes
    /// every `displayInterval` ms; true when the pane should render at full rate.
    mutating func record(intervals: [Double], displayInterval: Double, at now: Date) -> Bool {
        let capped = Self.cappedInterval(displayInterval)
        guard intervals.count >= Self.minimumFrames, capped > displayInterval else { return fullRate }
        let elapsed = changedAt.map { now.timeIntervalSince($0) } ?? .infinity
        if fullRate {
            if Self.lateShare(intervals, expected: displayInterval) > Self.overloaded {
                // Full rate that fails soon after it came back waits longer next time.
                backoff = elapsed < backoff ? min(backoff * 2, Self.maximumBackoff) : Self.firstBackoff
                fullRate = false
                changedAt = now
            }
        } else if elapsed >= backoff, Self.lateShare(intervals, expected: capped) <= Self.recovered {
            fullRate = true
            changedAt = now
        }
        return fullRate
    }

    /// WebKit's capped frame interval: the display-rate divisor at or above
    /// 60 fps (80 Hz on a 160 Hz display, 60 Hz on 120 Hz).
    static func cappedInterval(_ displayInterval: Double) -> Double {
        guard displayInterval > 0 else { return 0 }
        return displayInterval * max(1, ((1000.0 / 60 + 0.01) / displayInterval).rounded(.down))
    }

    private static func lateShare(_ intervals: [Double], expected: Double) -> Double {
        Double(intervals.count { $0 > expected * lateFactor }) / Double(intervals.count)
    }
}
