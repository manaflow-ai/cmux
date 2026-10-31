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
    /// restore bound passed, or no answer), or the connected daemon leaves its
    /// heartbeat unanswered (``daemonNotAnswering``): `--replace-unresponsive`
    /// cannot tell a stuck owner from a slow restore, so it is offered only then.
    public private(set) var offersRestart = false
    /// The connected daemon leaves its heartbeat unanswered while its process is alive (stopped or wedged): its
    /// connection stays open and its requests keep waiting (P0 2026-10-30), and Restart is offered.
    public private(set) var daemonNotAnswering = false
    /// The launcher's last ensure looked stuck (``DaemonLauncher/EnsureOutcome/ownerLooksStuck``).
    @ObservationIgnored private var ensureLooksStuck = false
    /// The `server ensure` a not-answering daemon's heartbeat started (``noteDaemonAnswering(_:)``), with its
    /// generation so only its own end clears it; nil when none runs.
    @ObservationIgnored private var ownerProbe: (generation: UInt64, task: Task<Void, Never>)?
    @ObservationIgnored private var ownerProbeGeneration: UInt64 = 0
    /// The service runs a connection: false after ``stopProbing()`` (its shutdown), so no probe starts behind it.
    @ObservationIgnored private var probing = true
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
        probing = true
        outcome.observe(on: work, .visible, owner: "DaemonRecovery.offersRestart") { [weak self] in
            guard let self else { return }
            ensureLooksStuck = outcome.ownerLooksStuck
            // An ensure that worked (the owner recovered by itself) ends an earlier Restart's failure.
            if !ensureLooksStuck { restartFailure = nil }
            updateOffer()
        }
        ensureLooksStuck = outcome.ownerLooksStuck
        updateOffer()
    }

    /// The connected daemon answers its heartbeat (true) or left one more ask unanswered while its connection stays
    /// open (false; ``DaemonConnection/observeAnswering(_:)``). While it does not answer, each unanswered ask runs one
    /// plain `server ensure` when none runs, so the offer judges the owner as it did when a missed heartbeat closed
    /// the connection and the reconnect ran the ensure; the connection and its requests wait meanwhile.
    func noteDaemonAnswering(_ answering: Bool) {
        // A post that was in flight when the service shut its connection down says nothing about a connection it runs.
        guard probing || answering else { return }
        if daemonNotAnswering == answering {
            daemonNotAnswering = !answering
            logger.notice("cmux-tui \(answering ? "answers again" : "is not answering; its connection stays open", privacy: .public)")
            updateOffer()
        }
        if answering {
            endProbe()
        } else {
            probeOwner()
        }
    }

    /// The service shut its connection down: no probe runs or starts behind it.
    func stopProbing() {
        probing = false
        endProbe()
        daemonNotAnswering = false
        updateOffer()
    }

    /// One `server ensure` for the offer, unless one runs already or the service stopped.
    private func probeOwner() {
        guard probing, ownerProbe == nil, let launcher else { return }
        ownerProbeGeneration &+= 1
        let generation = ownerProbeGeneration
        // task-owner: one ensure at a time (`ownerProbe`), bounded by the ensure's own deadlines; an answer or
        // `stopProbing` cancels it. Off main: it awaits the ensure process; its one step on main ends its own handle.
        let task = Task { @concurrent [weak self] in
            await launcher.probeOwner()
            await self?.ownerProbeEnded(generation)
        }
        ownerProbe = (generation, task)
    }

    /// Clears the probe handle only when it is still probe `generation`'s: a cancelled probe never clears a newer one.
    private func ownerProbeEnded(_ generation: UInt64) {
        guard ownerProbe?.generation == generation else { return }
        ownerProbe = nil
    }

    private func endProbe() {
        ownerProbe?.task.cancel()
        ownerProbe = nil
    }

    /// Restart is offered while an ensure looked stuck or the connected daemon does not answer, and a launcher is known.
    private func updateOffer() {
        offersRestart = launcher != nil && (ensureLooksStuck || daemonNotAnswering)
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
