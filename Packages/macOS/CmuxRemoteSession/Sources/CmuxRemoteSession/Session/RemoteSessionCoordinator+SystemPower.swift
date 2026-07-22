internal import Foundation

extension RemoteSessionCoordinator {
    /// Pauses reconnect-policy accounting while the local Mac is asleep.
    public func prepareForSystemSleep() {
        queue.async { [weak self] in
            self?.prepareForSystemSleepLocked()
        }
    }

    /// Clears any terminal reconnect suspension after an external re-arm signal.
    ///
    /// A reconnect is scheduled when the coordinator was suspended or no longer
    /// has a ready proxy. Healthy connections are left in place; a transport
    /// failure delivered after wake will schedule through the freshly reset policy.
    ///
    /// - Parameter reason: A diagnostic label for the re-arm signal.
    public func resetReconnectPolicyAndReconnect(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let shouldReconnect = self.resetReconnectPolicyLocked(reason: reason)
            guard shouldReconnect else { return }
            self.resetTransportForReconnectLocked()
            _ = self.scheduleReconnectLocked(baseDelay: 2.0)
        }
    }

    func prepareForSystemSleepLocked() {
        guard !isStopping else { return }
        isSystemSleeping = true
        cancelReconnectRetryLocked()
        reachabilityProbeGeneration &+= 1
        debugLog("remote.session.systemSleep \(debugConfigSummary())")
    }

    @discardableResult
    func resetReconnectPolicyLocked(reason: String) -> Bool {
        guard !isStopping else { return false }
        let expectsProxyEndpoint = !configuration.skipDaemonBootstrap ||
            configuration.daemonWebSocketEndpoint != nil
        let shouldReconnect = reconnectSuspended || reconnectRetryCount > 0 ||
            (expectsProxyEndpoint && proxyEndpoint == nil) || !daemonReady
        isSystemSleeping = false
        cancelReconnectRetryLocked()
        reconnectRetryCount = 0
        consecutiveUnreachableProbeCount = 0
        reconnectSuspended = false
        reachabilityProbeGeneration &+= 1
        debugLog(
            "remote.session.reconnect.rearmed reason=\(reason.debugLogSnippet(limit: 80)) " +
                "reconnect=\(shouldReconnect ? 1 : 0) \(debugConfigSummary())"
        )
        return shouldReconnect
    }

    private func resetTransportForReconnectLocked() {
        cancelTransportDependentWorkLocked()
        cancelReverseRelayRestartLocked()
        stopReverseRelayLocked()
        failPendingPTYBridgeStartsLocked("remote daemon is not ready")
        releaseProxyLeaseLocked()
        proxyEndpoint = nil
        daemonReady = false
        daemonBootstrapVersion = nil
        daemonRemotePath = nil
        publishProxyEndpoint(nil)
    }

    private func cancelTransportDependentWorkLocked() {
        bootstrapRemoteTTYResolved = false
        bootstrapRemoteTTYFetchInFlight = false
        suspendRemotePortScanningLocked()
    }

    func releaseProxyLeaseLocked() {
        proxyLeaseGeneration &+= 1
        proxyLease?.release()
        proxyLease = nil
    }
}
