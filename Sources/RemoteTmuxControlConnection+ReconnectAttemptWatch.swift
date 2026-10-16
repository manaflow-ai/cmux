import Foundation

/// Gives up on a reconnect attempt whose transport stays quiet.
///
/// A reconnect spawns the transport and waits for tmux's `%enter`. If the transport hangs
/// before printing anything (a proxy wrapper that never starts the real client was seen
/// sitting like that for eight and a half minutes), nothing else ever ends the attempt and the
/// mirror stays frozen. The first attach already judges a quiet login against
/// ``RemoteTmuxAttachProgress/QuietLimits``; a reconnect attempt uses the same verdict, so any
/// output from the transport moves the limit out, and only a transport that says nothing for
/// the whole limit is killed and replaced by a fresh attempt.
@MainActor
extension RemoteTmuxControlConnection {
    func watchReconnectAttempt(processGeneration generation: UInt64) {
        Task { @MainActor [weak self] in
            while let milliseconds = self?.reconnectAttemptWatchStep(processGeneration: generation) {
                await RemoteTmuxRetryDelay.wait(milliseconds: milliseconds)
            }
        }
    }

    /// Checks the attempt once. Returns how long to wait before checking again, or nil when
    /// there is nothing left to watch: the attempt reached tmux, ended, was replaced, or was
    /// just abandoned here.
    private func reconnectAttemptWatchStep(processGeneration generation: UInt64) -> Int? {
        guard connectionState == .reconnecting, processGeneration == generation, !enterReceived,
              let progress = attachProgress(), progress.phase == .loggingIn else { return nil }
        switch progress.verdict(limits: reconnectQuietLimits) {
        case .stalled:
            record("reconnect-attempt-stalled quiet=\(progress.quietFor)")
            teardownProcessHandles()
            scheduleReconnectAttempt()
            return nil
        case let .wait(recheckIn):
            let (seconds, attoseconds) = recheckIn.components
            return max(1, Int(seconds) * 1_000 + Int(attoseconds / 1_000_000_000_000_000))
        }
    }
}
