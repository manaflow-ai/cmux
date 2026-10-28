import CmuxNextWakeups

/// The one-shot deadline of ``ChromiumHostHangMonitor`` (a ``DemandTimer``; a fake in tests).
protocol ChromiumHostBusyDeadline: AnyObject {
    func schedule(after delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void)
    func cancel()
}

/// The monitor's deadline on a ``DemandTimer`` on the main thread's deadline queue, at most
/// ``ChromiumHostHangMonitor/leeway`` after it, never before.
final class ChromiumHostBusyTimer: ChromiumHostBusyDeadline {
    private let timer: DemandTimer

    init(wakeUps: MainWakeUpQueue) {
        // timer-class-allow: the banner is due at 2000 +/- 100 ms; MainDeadline's flexible leeway at 2 s is 200 ms (10%, 1 s grid) and precise stops at 36 ms; this one is on the same main wake-up queue with 50 ms, and its action only sets a flag and adds one view
        timer = DemandTimer(owner: "chromium-host.busy", wakeUps: wakeUps)
    }

    func schedule(after delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void) {
        timer.scheduleOnMain(after: delay, tolerance: ChromiumHostHangMonitor.leeway, action)
    }

    func cancel() { timer.cancel() }
}
