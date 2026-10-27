import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import Foundation

/// A handoff of this connection's daemon that cuts no request (hq-6d 2026-10-14: a cut Home send is
/// the "Not Delivered" class). `quietHandoff` holds every new `request` and `resourceRequest`, waits
/// until none of this connection is in flight, then runs the handoff. When the daemon accepts it,
/// the held requests go to the next daemon once the connection is ready again; they go on anyway
/// (and fail as before) when the connection closes for good or after `handoffHoldLimit`. When it
/// refuses, they go on at once. One handoff at a time: a second waits until the first's hold ends.
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
        // A queued or quiet waiter dropped unresumed goes on as a resumed one does.
        while handoffHold != nil {
            _ = try? await withOnceContinuation { (next: OnceContinuation<Void, OnceContinuationError>) in handoffQueue.append(next) }
        }
        handoffHold = [:]
        if inFlight > 0 {
            _ = try? await withOnceContinuation { (quiet: OnceContinuation<Void, OnceContinuationError>) in quietWaiters.append(quiet) }
        }
        let startSerial = serial
        // concurrency-allow: async binding on the connection actor, always inside a Swift task (no fallback storage, cx-bpcj)
        let result = await Self.$passesHandoffHold.withValue(true) { await handoff() }
        if !accepted(result) || (isReady && serial != startSerial) {
            releaseHandoffHold()
        } else if handoffHold != nil {
            let timer = DemandTimer(owner: "DaemonConnection.handoffHold", clock: clock)
            handoffHoldTimer = timer
            timer.schedule(after: Self.handoffHoldLimit) { [weak self] in await self?.releaseHandoffHold() }
        }
        return result
    }

    /// A request waits here while a quiet handoff runs (or until its task is cancelled).
    func waitOutHandoff() async {
        while handoffHold != nil, !Self.passesHandoffHold, !Task.isCancelled {
            handoffHoldNext += 1
            let key = handoffHoldNext
            await withTaskCancellationHandler {
                _ = try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
                    guard handoffHold == nil else {
                        handoffHold?[key] = continuation
                        return
                    }
                    continuation.resume(returning: ())
                }
            } onCancel: {
                // task-owner: one hop back to the actor to resume this cancelled request's continuation
                Task { await self.leaveHandoffHold(key) }
            }
        }
    }

    private func leaveHandoffHold(_ key: UInt64) {
        handoffHold?.removeValue(forKey: key)?.resume(returning: ())
    }

    func requestStarted() { inFlight += 1 }

    func requestEnded() {
        inFlight -= 1
        guard inFlight == 0, !quietWaiters.isEmpty else { return }
        let waiters = quietWaiters
        quietWaiters.removeAll()
        waiters.forEach { $0.resume(returning: ()) }
    }

    /// Lets the held requests go (a new connection is ready, the connection closed, the handoff
    /// was refused, or the hold limit passed), then the next queued handoff.
    func releaseHandoffHold() {
        guard let held = handoffHold else { return }
        handoffHold = nil
        handoffHoldTimer?.cancel()
        handoffHoldTimer = nil
        held.values.forEach { $0.resume(returning: ()) }
        let queued = handoffQueue
        handoffQueue.removeAll()
        queued.forEach { $0.resume(returning: ()) }
    }
}
