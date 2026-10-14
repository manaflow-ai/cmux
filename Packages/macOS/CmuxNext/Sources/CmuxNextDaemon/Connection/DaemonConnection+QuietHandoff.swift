import Foundation

/// A handoff of this connection's daemon that cuts no request (hq-6d 2026-10-14: a cut Home send is
/// the "Not Delivered" class). `quietHandoff` holds every new `request` and `resourceRequest`, waits
/// until none of this connection is in flight, then runs the handoff. When the daemon accepts it,
/// the held requests go to the next daemon once the connection is ready again (or fail as before
/// when the connection closes for good); when it refuses, they go on at once.
extension DaemonConnection {
    /// The handoff's own requests pass the hold.
    @TaskLocal static var passesHandoffHold = false

    /// Runs `handoff` (true: the daemon accepted it and will exit) with no request in flight.
    public func quietHandoff(_ handoff: @Sendable () async -> Bool) async -> Bool {
        guard handoffHold == nil else { return false }
        handoffHold = []
        if inFlight > 0 { await withCheckedContinuation { quietWaiters.append($0) } }
        let startSerial = serial
        let accepted = await Self.$passesHandoffHold.withValue(true) { await handoff() }
        // Refused, or the connection is already a new one: nothing to wait for.
        if !accepted || serial != startSerial { releaseHandoffHold() }
        return accepted
    }

    /// A request waits here while a quiet handoff runs.
    func waitOutHandoff() async {
        guard handoffHold != nil, !Self.passesHandoffHold else { return }
        await withCheckedContinuation { handoffHold?.append($0) }
    }

    func requestStarted() { inFlight += 1 }

    func requestEnded() {
        inFlight -= 1
        guard inFlight == 0, !quietWaiters.isEmpty else { return }
        let waiters = quietWaiters
        quietWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Lets the held requests go (a new connection is ready, the connection closed, or the handoff was refused).
    func releaseHandoffHold() {
        guard let held = handoffHold else { return }
        handoffHold = nil
        held.forEach { $0.resume() }
    }
}
