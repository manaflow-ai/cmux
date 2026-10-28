public import CmuxNextWakeups

/// Where the launch starts the Chromium Host: one post named `ChromiumHost.start`,
/// decided once the launch's restore finished, when the restored panes exist. Before the restore no pane shows its Chromium tab yet, so a
/// decision then would always find none. A launch whose startup completes with no restore (the daemon
/// unavailable, the failsafe) decides then from what it has.
@MainActor
public final class ChromiumHostLaunchSlot {
    private let startup: StartupScheduler
    private let decide: @MainActor () -> ChromiumHostLaunchStart?
    private let start: @MainActor @Sendable (ChromiumHostLaunchStart) -> Void
    private let noStart: @MainActor @Sendable () -> Void
    /// What it decided: the host's start, or nil when nothing made Chromium likely; unset until then.
    public private(set) var decided: ChromiumHostLaunchStart??

    /// - Parameters:
    ///   - startup: The launch's scheduler.
    ///   - decide: Where the restored windows put the host's start (``ChromiumHostLaunchStart``), read once.
    ///   - start: Starts the host for a decided start, in the `ChromiumHost.start` post at its priority.
    ///   - noStart: Nothing made Chromium likely: the warm-up's own wait decides later, posted after the first frame.
    public init(startup: StartupScheduler, decide: @escaping @MainActor () -> ChromiumHostLaunchStart?,
                start: @escaping @MainActor @Sendable (ChromiumHostLaunchStart) -> Void, noStart: @escaping @MainActor @Sendable () -> Void) {
        (self.startup, self.decide, self.start, self.noStart) = (startup, decide, start, noStart)
        startup.whenComplete { [weak self] _ in self?.post() }
    }

    /// The launch's restore finished: the restored panes decide.
    public func restored() {
        post()
    }

    private func post() {
        guard decided == nil else { return }
        let decision = decide()
        decided = .some(decision)
        guard let decision else { return startup.post(.afterFirstFrame, "ChromiumWarmup.arm", on: .main, noStart) }
        let start = start
        startup.post(decision.priority, "ChromiumHost.start", on: .main) { start(decision) }
    }
}
