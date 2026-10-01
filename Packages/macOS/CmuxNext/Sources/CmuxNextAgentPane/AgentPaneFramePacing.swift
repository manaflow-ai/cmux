import Foundation

/// Chooses the agent pane's rendering rate from how its scrolls paced.
nonisolated struct AgentPaneFramePacing: Equatable, Sendable {
    /// Scrolls shorter than this many frames decide nothing.
    static let minimumFrames = 30
    /// The first wait at the capped rate before full rate is tried again.
    static let firstBackoff: TimeInterval = 10

    /// Records one scroll's frame intervals (ms) on a display that refreshes
    /// every `displayInterval` ms; true when the pane should render at full rate.
    mutating func record(intervals: [Double], displayInterval: Double, at now: Date) -> Bool {
        true
    }
}
