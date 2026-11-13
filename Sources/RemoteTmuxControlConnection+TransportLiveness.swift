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
