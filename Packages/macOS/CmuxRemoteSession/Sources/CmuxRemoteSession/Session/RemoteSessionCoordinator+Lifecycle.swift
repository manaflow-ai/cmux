extension RemoteSessionCoordinator {
    /// Stops the session after all queue-confined cleanup has completed.
    ///
    /// - Parameter cleanupScope: The ownership scope released by this stop.
    /// - Returns: `true` when the requested remote cleanup completed successfully.
    public func stopAndWait(cleanupScope: RemoteRelayCleanupScope = .persistentSlot) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: stopAllLocked(cleanupScope: cleanupScope))
            }
        }
    }

    @discardableResult
    func stopAllLocked(cleanupScope: RemoteRelayCleanupScope) -> Bool {
        debugLog("remote.session.stop \(debugConfigSummary())")
        isStopping = true
        cancelConnectionAttemptLocked()
        cancelReconnectRetryLocked()
        reconnectRetryCount = 0
        consecutiveUnreachableProbeCount = 0
        reconnectSuspended = false
        reachabilityProbeGeneration &+= 1
        cancelReverseRelayRestartLocked()
        cancelRemotePortScanCoalesceLocked()
        let cleanupSucceeded = stopReverseRelayLocked(cleanupScope: cleanupScope)
        remotePortScanGeneration &+= 1
        remotePortScanBurstTask?.cancel()
        remotePortScanBurstTask = nil
        remotePortScanBurstActive = false
        remotePortScanActiveReason = nil
        remotePortScanPendingReason = nil
        remotePortScanTTYNames.removeAll()
        remotePortScanSnapshot.reset()
        stopRemotePortPollingLocked()
        remotePortPollState.reset()
        keepPolledRemotePortsUntilTTYScan = false
        bootstrapRemoteTTYResolved = false
        cancelBootstrapRemoteTTYRetryLocked()
        bootstrapRemoteTTYFetchInFlight = false
        bootstrapRemoteTTYRetryCount = 0
        failPendingPTYBridgeStartsLocked("remote daemon is not ready")

        releaseProxyLeaseLocked()
        proxyEndpoint = nil
        daemonReady = false
        daemonBootstrapVersion = nil
        // A detached persistent owner may need the resolved binary path for a
        // later final stop when no relay metadata was ever provisioned.
        if configuration.persistentDaemonSlot == nil ||
            (cleanupScope == .persistentSlot && cleanupSucceeded) {
            daemonRemotePath = nil
        }
        publishProxyEndpoint(nil)
        publishPortsSnapshotLocked()
        return cleanupSucceeded
    }
}
