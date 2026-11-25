import Foundation

/// Keeps the Mac and its display from idle sleep while Sleepy Mode shows, the in-process
/// `caffeinate -d -i`. Its own activity, apart from `KeepAwakeService`'s, so ending Sleepy
/// Mode never ends Keep Mac Awake or an agent's hold (and those never end this one).
@MainActor
public final class SleepyKeepAwakeActivity: SleepyKeepAwakeHolding {
    private var activity: (any NSObjectProtocol)?

    /// An activity that holds nothing yet.
    public init() {}

    /// True while the hold is on.
    public var isHolding: Bool { activity != nil }

    /// Starts the hold. A second call does nothing.
    public func begin() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled], reason: "cmux Sleepy Mode")
    }

    /// Ends the hold. Does nothing when none is on.
    public func end() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}
