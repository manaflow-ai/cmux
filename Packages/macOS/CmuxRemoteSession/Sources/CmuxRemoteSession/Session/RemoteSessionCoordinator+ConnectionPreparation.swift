internal import CmuxCore
internal import CmuxRemoteDaemon
internal import CmuxRemoteWorkspace
internal import Foundation

extension RemoteSessionCoordinator {
    func beginConnectionAttemptLocked() {
        guard !isStopping else { return }
        cancelConnectionPreparationLocked()
        let token = UUID()
        connectionPreparationToken = token
        let reaper = orphanedProcessReaper
        let destination = configuration.destination
        let relayPort = configuration.relayPort
        let persistentDaemonSlot = configuration.persistentDaemonSlot
        connectionPreparationTask = Task { [weak self] in
            await reaper.reap(
                destination: destination,
                relayPort: relayPort,
                persistentDaemonSlot: persistentDaemonSlot
            )
            guard !Task.isCancelled else { return }
            self?.queue.async { [weak self] in
                self?.connectionPreparationDidFinishLocked(token: token)
            }
        }
    }

    private func connectionPreparationDidFinishLocked(token: UUID) {
        guard connectionPreparationToken == token else { return }
        connectionPreparationTask = nil
        connectionPreparationToken = nil
        guard !isStopping else { return }
        beginConnectionAttemptAfterOrphanCleanupLocked()
    }

    func cancelConnectionPreparationLocked() {
        connectionPreparationTask?.cancel()
        connectionPreparationTask = nil
        connectionPreparationToken = nil
    }

    private func beginConnectionAttemptAfterOrphanCleanupLocked() {
        connectionAttemptStartedAt = Date()
        debugLog("remote.session.connect.begin retry=\(reconnectRetryCount) \(debugConfigSummary())")
        // The armed retry (if any) is consumed by this attempt; a stale fire
        // is dropped by the token guard (legacy dropped the work-item
        // reference here).
        reconnectTask = nil
        reconnectToken = nil
        cancelBootstrapRemoteTTYRetryLocked()
        bootstrapRemoteTTYFetchInFlight = false
        if remotePortScanTTYNames.isEmpty {
            bootstrapRemoteTTYResolved = false
            bootstrapRemoteTTYRetryCount = 0
        }
        let connectDetail: String
        let bootstrapDetail: String
        let connectionState: WorkspaceRemoteConnectionState
        if reconnectRetryCount > 0 {
            connectionState = .reconnecting
            connectDetail = "Reconnecting to \(configuration.displayTarget) (retry \(reconnectRetryCount))"
            bootstrapDetail = "Bootstrapping remote daemon on \(configuration.displayTarget) (retry \(reconnectRetryCount))"
        } else {
            connectionState = .connecting
            connectDetail = "Connecting to \(configuration.displayTarget)"
            bootstrapDetail = "Bootstrapping remote daemon on \(configuration.displayTarget)"
        }
        publishState(connectionState, detail: connectDetail)
        publishDaemonStatus(.bootstrapping, detail: bootstrapDetail)
        do {
            let requiredCapabilities = requiredDaemonCapabilities
            let hello: DaemonHello
            if configuration.skipDaemonBootstrap {
                // Cloud-VM path: cmuxd-remote is pre-baked in the image and exposed via
                // systemd socket activation at /run/cmuxd-remote.sock. We skip the probe,
                // upload, and stdio-hello steps entirely — they all depend on ssh-exec
                // channel I/O, which the Freestyle gateway doesn't forward.
                hello = Self.bakedVMDaemonHello()
                debugLog("remote.bootstrap.skipped reason=vm-baked remotePath=\(hello.remotePath)")
            } else {
                hello = try bootstrapDaemonLocked(requiredCapabilities: requiredCapabilities)
            }
            let preflightRequiredCapabilities = configuration.skipDaemonBootstrap
                ? bakedDaemonPreflightRequiredCapabilities
                : requiredCapabilities
            let missingCapabilities = Self.missingRequiredCapabilities(
                preflightRequiredCapabilities,
                in: hello.capabilities
            )
            guard missingCapabilities.isEmpty else {
                throw NSError(domain: "cmux.remote.daemon", code: 43, userInfo: [
                    NSLocalizedDescriptionKey: daemonStrings.missingRequiredCapabilitiesMessage(missingCapabilities),
                    NSDebugDescriptionErrorKey: "remote daemon missing required capability \(missingCapabilities.joined(separator: ","))",
                ])
            }
            daemonReady = true
            daemonBootstrapVersion = hello.version
            daemonRemotePath = hello.remotePath
            publishDaemonStatus(
                .ready,
                detail: "Remote daemon ready",
                version: hello.version,
                name: hello.name,
                capabilities: hello.capabilities,
                remotePath: hello.remotePath
            )
            recordHeartbeatActivityLocked()
            if configuration.skipDaemonBootstrap {
                debugLog("remote.relay.skipped reason=vm-baked transport=\(configuration.transport.rawValue)")
                if configuration.daemonWebSocketEndpoint != nil {
                    startProxyLocked()
                } else {
                    // SSH-only cloud VM fallback cannot use ssh-exec or local socket forwarding
                    // through provider gateways. Keep the shell connected and leave proxy off.
                    publishState(
                        .connected,
                        detail: String(format: strings.connectedVMNoProxyFormat, configuration.displayTarget)
                    )
                }
            } else {
                startReverseRelayLocked(remotePath: hello.remotePath)
                requestBootstrapRemoteTTYIfNeededLocked()
                startProxyLocked()
            }
        } catch {
            daemonReady = false
            daemonBootstrapVersion = nil
            daemonRemotePath = nil
            let retrySchedule = scheduleReconnectLocked(baseDelay: 4.0)
            let retrySuffix = Self.retrySuffix(retry: retrySchedule.retry, delay: retrySchedule.delay)
            let detail = "Remote daemon bootstrap failed: \(Self.userFacingRemoteDaemonBootstrapErrorMessage(error, strings: daemonStrings))\(retrySuffix)"
            publishDaemonStatus(.error, detail: detail)
            publishState(.error, detail: detail)
        }
    }

}
