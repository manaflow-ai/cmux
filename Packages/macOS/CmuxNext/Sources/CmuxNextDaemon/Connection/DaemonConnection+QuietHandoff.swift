import CmuxNextWakeups
import Foundation

/// A handoff of this connection's daemon that cuts no request (hq-6d 2026-10-14: a cut Home send is
/// the "Not Delivered" class). `quietHandoff` holds every new `request` and `resourceRequest`, waits
/// until none of this connection is in flight, then runs the handoff. When the daemon accepts it,
/// the held requests go to the next daemon once the connection is ready again; they go on anyway
/// (and fail as before) when the connection closes for good or after `handoffHoldLimit`. When it
/// refuses, they go on at once. One handoff at a time: a second waits until the first's hold ends.
///
/// The requests pass the hold through ``QuietHandoffGate`` without the actor; only the
/// handoff itself and the hold's end run here.
extension DaemonConnection {
    /// The handoff's own requests pass the hold.
    @TaskLocal static var passesHandoffHold = false
    /// The longest a request waits for the next daemon: the launcher's 60 s wait for the old
    /// daemon to exit, plus a request deadline.
    static let handoffHoldLimit: Duration = .seconds(65)

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
        if !accepted(result) || (isReady && serial != startSerial) {
            releaseHandoffHold(hold)
        } else if handoffGate.holds(hold) {
            // timer-class-allow: off main: the hold's limit releases it on the connection's actor; no main-thread job
            let timer = DemandTimer(owner: "DaemonConnection.handoffHold", clock: clock)
            handoffHoldTimer = timer
            timer.schedule(after: Self.handoffHoldLimit) { [weak self] in await self?.releaseHandoffHold(hold) }
        }
        return result
    }

    /// Lets the held requests go (a new connection is ready, the connection closed, the handoff
    /// was refused, or the hold limit passed), then the next queued handoff. `hold` names the
    /// handoff whose hold ends; nil ends whichever runs.
    func releaseHandoffHold(_ hold: QuietHandoffGate.Hold? = nil) {
        guard handoffGate.release(hold) else { return }
        handoffHoldTimer?.cancel()
        handoffHoldTimer = nil
    }
}
