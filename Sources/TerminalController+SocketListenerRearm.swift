import CmuxControlSocket
import Foundation

extension TerminalController {
    nonisolated func scheduleListenerRearm(
        generation: UInt64,
        errnoCode: Int32,
        consecutiveFailures: Int,
        delayMs: Int
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Bounded rearm delay on the server's injected recovery clock
            // (replaces the legacy main-queue asyncAfter); a stale fire is a
            // no-op via the pending-rearm generation guard in the claim.
            try? await self.socketServer.recoveryClock.sleep(forMilliseconds: delayMs)
            guard let restartPath = self.socketServer.claimPendingRearm(
                generation: generation,
                errnoCode: errnoCode,
                consecutiveFailures: consecutiveFailures,
                delayMs: delayMs
            ) else { return }

            let restartMode = self.socketServer.accessMode

            self.stop()
            self.startSocketTransport(
                SocketControlServerConfiguration(
                    accessMode: restartMode,
                    preferredSocketPath: restartPath
                ),
                socketPath: restartPath,
                preserveAcceptFailureStreak: true
            )
        }
    }
}
