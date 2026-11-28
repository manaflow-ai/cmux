import Foundation

/// Gives up on a reconnect attempt whose transport stays quiet.
///
/// A reconnect spawns the transport and waits for tmux's `%enter`. If the transport hangs
/// before printing anything (a proxy wrapper that never starts the real client was seen
/// sitting like that for eight and a half minutes), nothing else ever ends the attempt and the
/// mirror stays frozen. The first attach already judges a quiet login against
/// ``RemoteTmuxAttachProgress/QuietLimits``; a reconnect attempt uses the same verdict.
///
/// One owner: ``reconnectAttemptDeadline`` is the attempt's single deadline. The spawn arms it,
/// every piece of transport output re-arms it for a full quiet limit, `%enter` or a teardown
/// (``teardownProcessHandles()``, which ``stop()`` runs too) cancels it, and only a deadline
/// that fires with no output since kills the attempt and schedules a fresh one.
@MainActor
extension RemoteTmuxControlConnection {
    func armReconnectAttemptDeadline() {
        scheduleReconnectAttemptDeadline(processGeneration: processGeneration)
    }

    func cancelReconnectAttemptDeadline() {
        reconnectAttemptDeadline?.cancel()
        reconnectAttemptDeadline = nil
    }

    /// Output from the transport is the progress edge: it moves an armed deadline out.
    func reconnectAttemptOutputArrived() {
        guard reconnectAttemptDeadline != nil else { return }
        guard connectionState == .reconnecting, !enterReceived else {
            cancelReconnectAttemptDeadline()
            return
        }
        scheduleReconnectAttemptDeadline(processGeneration: processGeneration)
    }

    /// The deadline fired. Judges the attempt once on ``transportClock``: stalled kills it and
    /// schedules a fresh attempt, otherwise the deadline is set for the time that remains.
    func reconnectAttemptDeadlineReached(processGeneration generation: UInt64) {
        reconnectAttemptDeadline = nil
        guard connectionState == .reconnecting, processGeneration == generation, !enterReceived,
              let progress = attachProgress(now: transportClock()), progress.phase == .loggingIn else { return }
        switch progress.verdict(limits: reconnectQuietLimits) {
        case .stalled:
            record("reconnect-attempt-stalled quiet=\(progress.quietFor)")
            teardownProcessHandles()
            scheduleReconnectAttempt()
        case .wait:
            scheduleReconnectAttemptDeadline(processGeneration: generation)
        }
    }

    private func scheduleReconnectAttemptDeadline(processGeneration generation: UInt64) {
        reconnectAttemptDeadline?.cancel()
        reconnectAttemptDeadline = nil
        guard let progress = attachProgress(now: transportClock()), progress.phase == .loggingIn else { return }
        let remaining: Duration
        switch progress.verdict(limits: reconnectQuietLimits) {
        case .stalled: remaining = .zero
        case let .wait(recheckIn): remaining = recheckIn
        }
        let (seconds, attoseconds) = remaining.components
        let milliseconds = max(1, Int(seconds) * 1_000 + Int(attoseconds / 1_000_000_000_000_000))
        reconnectAttemptDeadline = Task { @MainActor [weak self] in
            await RemoteTmuxRetryDelay.wait(milliseconds: milliseconds)
            guard !Task.isCancelled else { return }
            self?.reconnectAttemptDeadlineReached(processGeneration: generation)
        }
    }
}
