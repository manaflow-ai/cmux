import CmuxNextWakeups
import Foundation
import os

/// A handoff of this connection's daemon that cuts no request (hq-6d 2026-10-14: a cut Home send is
/// the "Not Delivered" class). `quietHandoff` holds every new `request` and `resourceRequest`, waits
/// until none of this connection is in flight, then runs the handoff. When the daemon accepts it,
/// the held requests go to the next daemon once the connection is ready again. They go on at once
/// when the daemon refuses, and fail as not connected when the connection closes for good. When no new
/// connection is ready within `handoffHoldLimit` they fail with ``DaemonError/handoffNotReady``, unsent:
/// a stuck handoff never makes an action wait silently. One handoff at a time: a second waits until the
/// first's hold ends.
///
/// Each hold is a measured stage (``handoffHoldStage``, `debug.daemon`'s `handoff_hold`, and one log line
/// per hold): the requests it held, how long, and how it ended.
///
/// Terminal key input never passes the hold: it goes by terminal on its attachment's transport
/// (`TerminalAttachment.enqueueInput`), not through `request`.
///
/// The requests pass the hold through ``QuietHandoffGate`` without the actor (p05-ipc-091); only the
/// handoff itself and the hold's end run here.
extension DaemonConnection {
    /// The handoff's own requests pass the hold.
    @TaskLocal static var passesHandoffHold = false
    /// The longest a request waits for the next daemon once the running one accepted the handoff, before
    /// it fails with ``DaemonError/handoffNotReady``.
    ///
    /// Why a hold at all: a request sent to the daemon that is exiting would be cut; held, it goes to the
    /// next one. Why this bound: a handoff that works ends well inside it. The old daemon exits right
    /// after its acknowledgement (its own teardown is bounded by cmux-tui's 2 s work wait and 5 s flush
    /// limits), the launcher hears the exit through the kernel's exit event, not a poll, and `server
    /// ensure` starts the bundled build, which adopts the running terminal hosts. Past it something is
    /// stuck: an old daemon that does not exit (the launcher waits up to 60 s for it) or a long restore
    /// (up to `DaemonLauncher.ensureRestoreCap`). Neither is a reason to keep a person's action waiting
    /// in silence: the action fails with a typed error now, and the connection keeps reconnecting under
    /// its usual status (the window's and sidebar's connecting state). It was 65 s (the launcher's exit
    /// wait plus a request deadline), during which every new request waited with nothing shown.
    public static let handoffHoldLimit: Duration = .seconds(5)

    /// The quiet handoff's holds so far, and the running one (diagnostics: `debug.daemon`).
    public nonisolated var handoffHoldStage: HandoffHoldStage { handoffGate.stage }

    /// Runs `handoff` (true: the daemon accepted it and will exit) with no request in flight.
    public func quietHandoff(_ handoff: @Sendable () async -> Bool) async -> Bool {
        await quietHandoff(handoff, accepted: { $0 })
    }

    /// `quietHandoff` for a handoff whose result says whether the daemon accepted it.
    public func quietHandoff<Result: Sendable>(_ handoff: @Sendable () async -> Result,
                                               accepted: (Result) -> Bool) async -> Result {
        let hold = await handoffGate.beginHandoff()
        let startSerial = serial
        // concurrency-allow: async binding on the connection actor, always inside a Swift task (no fallback storage, cx-bpcj)
        let result = await Self.$passesHandoffHold.withValue(true) { await handoff() }
        if !accepted(result) {
            releaseHandoffHold(hold, end: .refused)
        } else if isReady && serial != startSerial {
            // The next daemon is ready already.
            releaseHandoffHold(hold, end: .ready)
        } else if handoffGate.holds(hold) {
            // timer-class-allow: off main: the hold's limit releases it on the connection's actor; no main-thread job
            let timer = DemandTimer(owner: "DaemonConnection.handoffHold", clock: clock)
            handoffHoldTimer = timer
            timer.schedule(after: Self.handoffHoldLimit) { [weak self] in await self?.releaseHandoffHold(hold, end: .limit) }
        }
        return result
    }

    /// Ends the hold as `end` says (a new connection is ready, the connection closed, the handoff was
    /// refused, or the hold limit passed), then lets the next queued handoff run. `hold` names the
    /// handoff whose hold ends; nil ends whichever runs.
    func releaseHandoffHold(_ hold: QuietHandoffGate.Hold? = nil, end: HandoffHoldEnd) {
        guard let ended = handoffGate.release(hold, end: end) else { return }
        handoffHoldTimer?.cancel()
        handoffHoldTimer = nil
        let milliseconds = String(format: "%.0f", ended.duration.inSeconds * 1_000)
        let message = "daemon handoff hold ended \(end.rawValue) after \(milliseconds) ms, \(ended.heldRequests) request(s) held"
        if end == .limit {
            Self.handoffLogger.error("\(message, privacy: .public)")
        } else {
            Self.handoffLogger.info("\(message, privacy: .public)")
        }
    }

    private static let handoffLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon")
}
