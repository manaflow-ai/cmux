import Foundation

/// Decides when a connected transport that has gone quiet should be asked whether it is still
/// there, and when its silence means it is gone.
///
/// A transport normally dies with its link, and the end of its stream starts a reconnect. Some do
/// not. A broker that keeps retrying a refused connection holds its process and its local pipe
/// open, so the mirror receives neither bytes nor an exit and stays frozen while it still counts
/// as connected. Nothing local marks that silence, so after ``probeAfterSilence`` with no stdout
/// the connection sends ``probeCommand``. Any stdout at all answers it. If none arrives within
/// ``probeReplyDeadline``, the transport is treated as dropped.
///
/// The probe is what declares a stall, never a count of outstanding commands, so a reply slot
/// that was never answered cannot make a quiet but healthy session reconnect.
struct RemoteTmuxTransportLiveness {
    /// How long stdout may stay silent before the connection asks.
    static let probeAfterSilence: Duration = .seconds(30)
    /// How long the probe may go unanswered before the transport counts as dropped.
    static let probeReplyDeadline: Duration = .seconds(30)
    /// `display-message -p` writes its format into the command's reply and changes nothing on
    /// the server. The empty format keeps that reply to one empty line.
    static let probeCommand = "display-message -p ''"

    enum Decision: Equatable {
        case wait(until: ContinuousClock.Instant)
        case probe
        case stall(silentFor: Duration)
    }

    /// When the transport last wrote to stdout.
    private(set) var lastStdoutAt: ContinuousClock.Instant?
    /// When the unanswered probe was sent. Cleared by any stdout.
    private(set) var probeSentAt: ContinuousClock.Instant?
    /// The one task that sleeps until the next decision is due, while the connection is connected.
    var watch: Task<Void, Never>?
    /// The clock stdout is stamped with. Tests replace it to move time by hand.
    var now: () -> ContinuousClock.Instant = { .now }

    mutating func noteStdout(at now: ContinuousClock.Instant) {
        lastStdoutAt = now
        probeSentAt = nil
    }

    mutating func noteProbeSent(at now: ContinuousClock.Instant) {
        probeSentAt = now
    }

    func decide(now: ContinuousClock.Instant) -> Decision {
        guard let lastStdoutAt else { return .wait(until: now + Self.probeAfterSilence) }
        if let probeSentAt {
            let due = probeSentAt + Self.probeReplyDeadline
            return now >= due ? .stall(silentFor: lastStdoutAt.duration(to: now)) : .wait(until: due)
        }
        let due = lastStdoutAt + Self.probeAfterSilence
        return now >= due ? .probe : .wait(until: due)
    }
}

extension RemoteTmuxControlConnection {
    /// Records stdout from the transport and makes sure a connected stream is being watched.
    func noteTransportStdout() {
        let now = transportLiveness.now()
        lastTransportOutputAt = now
        transportLiveness.noteStdout(at: now)
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
        if case .wait(let until) = transportLiveness.decide(now: now) { return until }
        return now
    }

    /// Acts on the liveness decision for `now`: sends the probe, or treats a probe that went
    /// unanswered as a dropped transport and reconnects.
    @discardableResult
    func checkTransportLiveness(now: ContinuousClock.Instant) -> RemoteTmuxTransportLiveness.Decision {
        guard connectionState == .connected else {
            return .wait(until: now + RemoteTmuxTransportLiveness.probeAfterSilence)
        }
        let decision = transportLiveness.decide(now: now)
        switch decision {
        case .wait:
            break
        case .probe:
            transportLiveness.noteProbeSent(at: now)
            record("liveness-probe")
            cmuxDebugLog("remote.stall.probe host=\(host.destination) pending=\(pendingCommands.count)")
            _ = sendTracked(RemoteTmuxTransportLiveness.probeCommand) { _ in }
        case .stall(let silentFor):
            // The reply can be in the pipe or the reader's stream, waiting for the main actor
            // this check is running on. Output that has arrived answers the probe.
            if stdoutPipeReader?.hasUndeliveredOutput == true {
                transportLiveness.noteStdout(at: now)
                record("liveness-reply-queued")
                return transportLiveness.decide(now: now)
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
