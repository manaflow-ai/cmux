import CmuxRemoteSession
import Foundation

/// The connection's side of the liveness check: the policy, the one task that sleeps until its
/// next decision, and the clock stdout is stamped with.
struct RemoteTmuxTransportLivenessState {
    var policy = RemoteTmuxTransportLiveness()
    /// The one task that sleeps until the next decision is due, while the connection is connected.
    var watch: Task<Void, Never>?
    /// The clock stdout is stamped with. Tests replace it to move time by hand.
    var now: () -> ContinuousClock.Instant = { .now }
    /// How long a reconnect attempt may run without reaching control mode before it is replaced. Long
    /// enough for a broker that waits on a security-key tap, which can take about a minute.
    var reconnectAttemptDeadline: Duration = .seconds(120)
    /// The task waiting out the current reconnect attempt's deadline.
    var reconnectAttemptWatch: Task<Void, Never>?
    /// When the current reconnect attempt expires, on the `now` clock, and the process it belongs to.
    var reconnectAttemptExpiry: (at: ContinuousClock.Instant, generation: UInt64)?

    var probeSentAt: ContinuousClock.Instant? { policy.probeSentAt }
}

extension RemoteTmuxControlConnection {
    /// Records stdout from the transport and makes sure a connected stream is being watched.
    func noteTransportStdout() {
        let now = transportLiveness.now()
        lastTransportOutputAt = now
        transportLiveness.policy.noteStdout(at: now)
        armTransportLivenessWatch()
    }

    private func armTransportLivenessWatch() {
        guard connectionState == .connected, transportLiveness.watch == nil else { return }
        transportLiveness.watch = Task { @MainActor [weak self] in
            while let wake = self?.nextTransportLivenessWake() {
                do {
                    try await ContinuousClock().sleep(until: wake)
                } catch {
                    break
                }
                guard let self else { break }
                self.checkTransportLiveness(now: self.transportLiveness.now())
            }
            self?.transportLiveness.watch = nil
        }
    }

    /// Gives the reconnect attempt just spawned until ``RemoteTmuxTransportLivenessState/reconnectAttemptDeadline``
    /// to reach control mode. The stall check watches only a connected stream, and a reconnect attempt
    /// is otherwise retried only when its stream ends. A transport that stays alive without reaching
    /// tmux, like a broker retrying a refused host, would hold the mirror frozen with no further try.
    /// At the deadline the attempt is ended and the normal backoff schedules the next one.
    func armReconnectAttemptDeadline() {
        transportLiveness.reconnectAttemptExpiry = (
            at: transportLiveness.now() + transportLiveness.reconnectAttemptDeadline,
            generation: processGeneration
        )
        let deadline = ContinuousClock.now + transportLiveness.reconnectAttemptDeadline
        transportLiveness.reconnectAttemptWatch?.cancel()
        transportLiveness.reconnectAttemptWatch = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(until: deadline)
            } catch {
                return
            }
            guard let self else { return }
            self.checkReconnectAttemptDeadline(now: self.transportLiveness.now())
        }
    }

    /// Replaces the reconnect attempt if it is still short of control mode at `now`, past its
    /// deadline. Returns whether it did.
    @discardableResult
    func checkReconnectAttemptDeadline(now: ContinuousClock.Instant) -> Bool {
        guard let expiry = transportLiveness.reconnectAttemptExpiry, now >= expiry.at,
              connectionState == .reconnecting, !awaitingInteractiveAuth,
              processGeneration == expiry.generation else { return false }
        transportLiveness.reconnectAttemptExpiry = nil
        let seconds = Int(transportLiveness.reconnectAttemptDeadline.components.seconds)
        record("reconnect-attempt-timeout after=\(seconds)s")
        cmuxDebugLog("remote.reconnect.timeout host=\(host.destination) after=\(seconds)s")
        teardownProcessHandles()
        scheduleReconnectAttempt()
        return true
    }

    /// When the watch should next look, or nil once the connection is no longer connected.
    private func nextTransportLivenessWake() -> ContinuousClock.Instant? {
        guard connectionState == .connected else { return nil }
        let now = transportLiveness.now()
        if case .wait(let until) = transportLiveness.policy.decide(now: now) { return until }
        return now
    }

    /// Acts on the liveness decision for `now`: sends the probe, or treats a probe that went
    /// unanswered as a dropped transport and reconnects.
    @discardableResult
    func checkTransportLiveness(now: ContinuousClock.Instant) -> RemoteTmuxTransportLiveness.Decision {
        guard connectionState == .connected else {
            return .wait(until: now + RemoteTmuxTransportLiveness.probeAfterSilence)
        }
        let decision = transportLiveness.policy.decide(now: now)
        switch decision {
        case .wait:
            break
        case .probe:
            transportLiveness.policy.noteProbeSent(at: now)
            record("liveness-probe")
            cmuxDebugLog("remote.stall.probe host=\(host.destination) pending=\(pendingCommands.count)")
            _ = sendTracked(RemoteTmuxTransportLiveness.probeCommand) { _ in }
        case .stall(let silentFor):
            // The reply can be in the pipe or the reader's stream, waiting for the main actor
            // this check is running on. Output that has arrived answers the probe.
            if stdoutPipeReader?.hasUndeliveredOutput == true {
                transportLiveness.policy.noteStdout(at: now)
                record("liveness-reply-queued")
                return transportLiveness.policy.decide(now: now)
            }
            let seconds = Int(silentFor.components.seconds)
            record("transport-stall silent=\(seconds)s")
            cmuxDebugLog(
                "remote.stall host=\(host.destination) silent=\(seconds)s pending=\(pendingCommands.count)")
            beginReconnecting()
        }
        return decision
    }
}
