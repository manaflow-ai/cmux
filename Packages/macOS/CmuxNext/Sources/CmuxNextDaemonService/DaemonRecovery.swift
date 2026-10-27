import CmuxNextDaemon
import CmuxNextWakeups
public import Observation
import os

/// The local daemon's recovery while it cannot be reached (cx-jniyz.1): the
/// launch window and the App Store's disconnected banner offer Retry Now and,
/// only after a plain `server ensure` failed as a stuck owner makes it fail
/// (``offersRestart``), Restart cmux-tui. Remote machines have no launcher,
/// so they offer neither.
@MainActor
@Observable
public final class DaemonRecovery {
    /// The last `server ensure` failed as a stuck owner makes it fail (the
    /// restore bound passed, or no answer): `--replace-unresponsive` cannot
    /// tell a stuck owner from a slow restore, so it is offered only then.
    public private(set) var offersRestart = false
    /// A Restart runs (up to 20 s of probe and stop, then the new owner's start).
    public private(set) var isRestarting = false
    /// Why the last Restart did not work (the refusal code or error, for Copy
    /// Details); nil after Retry Now or a Restart that worked.
    public private(set) var restartFailure: String?
    @ObservationIgnored private var launcher: DaemonLauncher?
    @ObservationIgnored private var wake: RetryWake?
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.daemon")

    public init() {}

    /// True once the local daemon's launcher is known (`DaemonService.start(launch:)`).
    public var canRetry: Bool { wake != nil }

    /// Follows `launcher`'s ensure outcomes, each change one visible task on `work` (the launch window shows the
    /// offer); `wake` is the service's retry wake.
    func attach(_ launcher: DaemonLauncher, wake: RetryWake, on work: MainWorkScheduler) {
        self.launcher = launcher
        self.wake = wake
        let outcome = launcher.ensureOutcome
        outcome.observe(on: work, .visible, owner: "DaemonRecovery.offersRestart") { [weak self] in
            guard let self else { return }
            offersRestart = outcome.ownerLooksStuck
            // An ensure that worked (the owner recovered by itself) ends an earlier Restart's failure.
            if !offersRestart { restartFailure = nil }
        }
        offersRestart = outcome.ownerLooksStuck
    }

    /// Tries to connect now instead of at the next backoff step.
    public func retryNow() {
        restartFailure = nil
        wake?.fire()
    }

    /// Stops the unresponsive owner and starts a new one (`server ensure
    /// --replace-unresponsive`), then tries to connect at once. SIGTERM
    /// leaves the terminal hosts running and the new owner adopts them.
    public func restart() async {
        guard let launcher, !isRestarting else { return }
        isRestarting = true
        restartFailure = nil
        do {
            let result = try await launcher.replaceUnresponsive()
            logger.notice("cmux-tui restart: \(result.status, privacy: .public), pid \(result.pid)")
        } catch {
            restartFailure = String(describing: error)
            logger.error("cmux-tui restart failed: \(String(describing: error), privacy: .public)")
        }
        isRestarting = false
        wake?.fire()
    }
}
