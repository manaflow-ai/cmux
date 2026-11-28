public import Foundation

/// `status.*` in cmux.json: when cmux shows work it was not told about, and
/// when a finished `cmux status run` notifies.
public nonisolated struct StatusBehaviorSettings: Hashable, Sendable {
    /// Show a busy indicator for a plain shell command (OSC 133) that runs
    /// longer than `inferCommandBusyAfter` seconds.
    public var inferCommandBusy = true
    public var inferCommandBusyAfter: Double = 3
    /// A finished run notifies when it took at least this many seconds...
    public var runNotifyMinimumSeconds: Double = 10
    /// ...and, unless this is on, only while its terminal is not visible.
    public var runNotifyWhenVisible = false

    public init() {}

    public static let inferAfterRange: ClosedRange<Double> = 0...600
    public static let runNotifyRange: ClosedRange<Double> = 0...3600
}
