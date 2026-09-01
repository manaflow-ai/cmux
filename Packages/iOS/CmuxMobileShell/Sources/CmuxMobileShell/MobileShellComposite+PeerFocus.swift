internal import CMUXMobileCore
internal import CmuxMobileRPC
import Foundation

@MainActor
extension MobileShellComposite {

    /// Apply the transport's current role and retry if focus moved while the
    /// session actor accepted that update. Rapid reversals therefore converge
    /// on the latest owner instead of letting a stale task win. A newer focus
    /// transition replaces this per-client maintenance task, so a fixed retry
    /// budget prevents pathological churn from retaining the old task.
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

    /// Drain and remove the prior peer's terminal registration only after the
    /// replacement listener has resolved. Rapid focus reversal leaves the now
    /// current client's registration intact.
    func cleanUpRetiredTerminalSubscription(
        _ pending: PendingTerminalSubscriptionHandoff,
        after readiness: MobileTerminalEventSubscriptionReadiness
    ) {
        Task { @MainActor [weak self] in
            _ = await readiness.wait()
            guard let self else { return }
            await self.drainTerminalSubscriptionHandoff(pending)
            // The old peer stays demoted whether or not the replacement
            // subscribe succeeded: failure recovery redials the CURRENT
            // foreground, never this client. Only a completed reversal (this
            // client owns focus again) keeps its registration; otherwise the
            // Mac would keep streaming terminal state to a control-only
            // session indefinitely.
            if self.remoteClient !== pending.client {
                _ = await self.unsubscribeTerminalEventStream(
                    on: pending.client
                )
            }
            self.finishTerminalSubscriptionHandoff(pending)
        }
    }
}
