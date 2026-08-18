internal import CMUXMobileCore
internal import CmuxMobileRPC
import Foundation

@MainActor
extension MobileShellComposite {
    /// Restore the existing listener if a synchronous handoff precondition
    /// rejects a focus transition before the connection changes.
    private func restoreTerminalSubscriptionAfterAbortedFastFocus(
        _ pending: PendingTerminalSubscriptionHandoff?
    ) {
        guard let pending else { return }
        Task { @MainActor [weak self] in
            await self?.drainTerminalSubscriptionHandoff(pending)
            guard let self else { return }
            self.finishTerminalSubscriptionHandoff(pending)
            guard self.remoteClient === pending.client else { return }
            self.startTerminalRefreshPolling()
        }
    }

    /// Reconcile the session actor's role after a focus transition. A focus
    /// reversal can race the first role update, so retry a bounded number of
    /// times until the update matches the current foreground owner.
    func synchronizeTransportSessionPurpose(
        _ client: MobileCoreRPCClient
    ) async {
        for _ in 0 ..< 3 {
            guard !Task.isCancelled else { return }
            let isForeground = remoteClient === client
            await client.updateTransportSessionPurpose(
                isForeground ? .foregroundControl : .backgroundControl
            )
            guard !Task.isCancelled else { return }
            guard (remoteClient === client) != isForeground else { return }
        }
    }

    /// Retire a previous terminal registration after the replacement listener
    /// is ready. This keeps rapid focus reversals from removing the current
    /// owner's registration.
    func cleanUpRetiredTerminalSubscription(
        _ pending: PendingTerminalSubscriptionHandoff,
        after readiness: MobileTerminalEventSubscriptionReadiness
    ) {
        Task { @MainActor [weak self] in
            _ = await readiness.wait()
            guard let self else { return }
            await self.drainTerminalSubscriptionHandoff(pending)
            if self.remoteClient !== pending.client {
                _ = await self.unsubscribeTerminalEventStream(
                    on: pending.client
                )
            }
            self.finishTerminalSubscriptionHandoff(pending)
        }
    }
}
