import Foundation

/// Keeps the Mac and its display from idle sleep while Sleepy Mode shows, the in-process
/// `caffeinate -d -i`. Its own activity, apart from `KeepAwakeService`'s, so ending Sleepy
/// Mode never ends Keep Mac Awake or an agent's hold (and those never end this one).
@MainActor
final class SleepyKeepAwakeActivity: SleepyKeepAwakeHolding {
    private var activity: (any NSObjectProtocol)?

    var isHolding: Bool { activity != nil }

    func begin() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled], reason: "cmux Sleepy Mode")
    }

    func end() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}
