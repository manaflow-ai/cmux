import CMUXMobileCore
import CmuxIrohTransport

extension MobileHostIrohRuntime {
    /// Applies a platform reachability transition to the host transport.
    ///
    /// Offline is a normal lifecycle state for a laptop, so broker refresh and
    /// endpoint recovery work is parked until the next usable path. The
    /// relay-policy task remains alive when a signed policy has an expiry
    /// deadline: it must still remove expired relay authority while the host is
    /// offline. Returning online cancels any stale broker wait and re-enters
    /// the existing single-flight refresh/reconcile paths immediately.
    func handleNetworkReachabilityChange(_ isReachable: Bool) {
        relayPolicyNetworkReachable = isReachable
        diagnosticLog.record(DiagnosticEvent(
            .reachabilityChanged,
            a: isReachable ? 1 : 0
        ))

        guard isReachable else {
            // Keep the refresh task's local expiry deadline. Its offline branch
            // performs only the local deactivation at policy expiry; no broker
            // request or retry is attempted until a reachable-path callback.
            if let revision = serverSignalRefreshRevision {
                serverSignalPendingRevision = max(
                    serverSignalPendingRevision ?? revision,
                    revision
                )
            }
            serverSignalRefreshTask?.cancel()
            serverSignalRefreshTask = nil
            serverSignalRefreshTaskID = nil
            serverSignalRefreshRevision = nil
            failureRecoveryTask?.cancel()
            failureRecoveryTask = nil
            return
        }

        if let service = relayPolicyRefreshService,
           let accountID = relayPolicyRefreshAccountID,
           let endpointID = relayPolicyRefreshEndpointID,
           let trustRoot = relayPolicyRefreshTrustRoot,
           let revision = relayPolicyRefreshRevision,
           revision == lifecycleRevision,
           activeAccountID == accountID {
            relayPolicyRefreshTask?.cancel()
            relayPolicyRefreshTask = nil
            relayPolicyRefreshTaskID = nil
            scheduleRelayPolicyRefresh(
                service: service,
                accountID: accountID,
                endpointID: endpointID,
                trustRoot: trustRoot,
                revision: revision,
                refreshImmediately: true
            )
        }
        if let pendingRevision = serverSignalPendingRevision,
           serverSignalRefreshTask == nil {
            serverSignalPendingRevision = nil
            reconcileConnectivityFromServerSignal(revision: pendingRevision)
        }
        retryIfNeeded()
    }
}
