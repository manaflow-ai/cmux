import CMUXMobileCore
import CmuxIrohTransport

extension MobileHostIrohRuntime {
    /// Applies a platform reachability transition to the host transport.
    ///
    /// Offline is a normal lifecycle state for a laptop, so relay-policy and
    /// endpoint recovery work is parked until the next usable path. Returning
    /// online cancels any stale wait and re-enters the existing single-flight
    /// refresh/reconcile paths immediately.
    func handleNetworkReachabilityChange(_ isReachable: Bool) {
        relayPolicyNetworkReachable = isReachable
        diagnosticLog.record(DiagnosticEvent(
            .reachabilityChanged,
            a: isReachable ? 1 : 0
        ))

        guard isReachable else {
            // The active refresh checks this flag after every suspension and
            // exits without arming another timer. Cancelling the task also
            // releases a clock wait promptly when the path drops during the
            // backoff interval.
            relayPolicyRefreshTask?.cancel()
            relayPolicyRefreshTask = nil
            relayPolicyRefreshTaskID = nil
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
