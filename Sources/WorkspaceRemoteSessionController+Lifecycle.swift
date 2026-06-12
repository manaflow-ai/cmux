import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Connection lifecycle and state publishing
extension WorkspaceRemoteSessionController {
    func start() {
        debugLog("remote.session.start \(debugConfigSummary())")
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isStopping else { return }
            self.beginConnectionAttemptLocked()
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopAllLocked()
            return
        }
        queue.async { [self] in
            stopAllLocked()
        }
    }

    func updateRemoteRelayIDAliases(workspaceAliases: [UUID: UUID], surfaceAliases: [UUID: UUID]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.remoteRelayWorkspaceAliases = workspaceAliases
            self.remoteRelaySurfaceAliases = surfaceAliases
            self.cliRelayServer?.updateRemoteRelayIDAliases(
                workspaceAliases: workspaceAliases,
                surfaceAliases: surfaceAliases
            )
        }
    }

    func runOnControllerQueue<T>(timeout: TimeInterval, _ body: @escaping () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var captured: Result<T, Error>?
        queue.async {
            let result = Result { try body() }
            lock.lock()
            captured = result
            lock.unlock()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw NSError(domain: "cmux.remote.pty", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "timed out waiting for remote PTY operation",
            ])
        }
        lock.lock()
        let result = captured
        lock.unlock()
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case nil:
            throw NSError(domain: "cmux.remote.pty", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "remote PTY operation returned no result",
            ])
        }
    }

    private func stopAllLocked() {
        debugLog("remote.session.stop \(debugConfigSummary())")
        isStopping = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectRetryCount = 0
        reverseRelayRestartWorkItem?.cancel()
        reverseRelayRestartWorkItem = nil
        remotePortScanCoalesceWorkItem?.cancel()
        remotePortScanCoalesceWorkItem = nil
        stopReverseRelayLocked()
        remotePortScanGeneration &+= 1
        remotePortScanBurstActive = false
        remotePortScanActiveReason = nil
        remotePortScanPendingReason = nil
        remotePortScanTTYNames.removeAll()
        remoteScannedPortsByPanel.removeAll()
        stopRemotePortPollingLocked()
        polledRemotePorts = []
        remotePortPollBaselinePorts = nil
        keepPolledRemotePortsUntilTTYScan = false
        bootstrapRemoteTTYResolved = false
        bootstrapRemoteTTYRetryWorkItem?.cancel()
        bootstrapRemoteTTYRetryWorkItem = nil
        bootstrapRemoteTTYFetchInFlight = false
        bootstrapRemoteTTYRetryCount = 0
        failPendingPTYBridgeStartsLocked("remote daemon is not ready")

        proxyLease?.release()
        proxyLease = nil
        proxyEndpoint = nil
        daemonReady = false
        daemonRemotePath = nil
        publishProxyEndpoint(nil)
        publishPortsSnapshotLocked()
    }

    private func beginConnectionAttemptLocked() {
        guard !isStopping else { return }

        Self.killOrphanedRemoteSSHProcesses(
            destination: configuration.destination,
            relayPort: configuration.relayPort,
            persistentDaemonSlot: configuration.persistentDaemonSlot
        )
        connectionAttemptStartedAt = Date()
        debugLog("remote.session.connect.begin retry=\(reconnectRetryCount) \(debugConfigSummary())")
        reconnectWorkItem = nil
        bootstrapRemoteTTYRetryWorkItem?.cancel()
        bootstrapRemoteTTYRetryWorkItem = nil
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
                    NSLocalizedDescriptionKey: remoteDaemonMissingRequiredCapabilitiesMessage(missingCapabilities),
                    NSDebugDescriptionErrorKey: "remote daemon missing required capability \(missingCapabilities.joined(separator: ","))",
                ])
            }
            daemonReady = true
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
                    let connectedDetailFormat = String(
                        localized: "remote.state.connected.vmNoProxy",
                        defaultValue: "Connected to %@ (VM, proxy disabled)"
                    )
                    publishState(
                        .connected,
                        detail: String(format: connectedDetailFormat, configuration.displayTarget)
                    )
                }
            } else {
                startReverseRelayLocked(remotePath: hello.remotePath)
                requestBootstrapRemoteTTYIfNeededLocked()
                startProxyLocked()
            }
        } catch {
            daemonReady = false
            daemonRemotePath = nil
            let retrySchedule = scheduleReconnectLocked(baseDelay: 4.0)
            let retrySuffix = Self.retrySuffix(retry: retrySchedule.retry, delay: retrySchedule.delay)
            let detail = "Remote daemon bootstrap failed: \(Self.userFacingRemoteDaemonBootstrapErrorMessage(error))\(retrySuffix)"
            publishDaemonStatus(.error, detail: detail)
            publishState(.error, detail: detail)
        }
    }

    private func startProxyLocked() {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard proxyLease == nil else { return }
        guard let remotePath = daemonRemotePath,
              !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let retrySchedule = scheduleReconnectLocked(baseDelay: 4.0)
            let retrySuffix = Self.retrySuffix(retry: retrySchedule.retry, delay: retrySchedule.delay)
            let detail = "Remote daemon did not provide a valid remote path\(retrySuffix)"
            publishDaemonStatus(.error, detail: detail)
            publishState(.error, detail: detail)
            return
        }

        let lease = WorkspaceRemoteProxyBroker.shared.acquire(
            configuration: configuration,
            remotePath: remotePath
        ) { [weak self] update in
            self?.queue.async {
                self?.handleProxyBrokerUpdateLocked(update)
            }
        }
        proxyLease = lease
    }

    private func handleProxyBrokerUpdateLocked(_ update: WorkspaceRemoteProxyBroker.Update) {
        guard !isStopping else { return }
        switch update {
        case .connecting:
            debugLog("remote.proxy.connecting \(debugConfigSummary())")
            if proxyEndpoint == nil {
                if reconnectRetryCount > 0 {
                    publishState(
                        .reconnecting,
                        detail: "Reconnecting to \(configuration.displayTarget) (retry \(reconnectRetryCount))"
                    )
                } else {
                    publishState(.connecting, detail: "Connecting to \(configuration.displayTarget)")
                }
            }
        case .ready(let endpoint):
            debugLog("remote.proxy.ready host=\(endpoint.host) port=\(endpoint.port) \(debugConfigSummary())")
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            reconnectRetryCount = 0
            guard proxyEndpoint != endpoint else {
                recordHeartbeatActivityLocked()
                fulfillPendingPTYBridgeStartsLocked()
                return
            }
            proxyEndpoint = endpoint
            publishProxyEndpoint(endpoint)
            fulfillPendingPTYBridgeStartsLocked()
            updateRemotePortPollingStateLocked()
            publishPortsSnapshotLocked()
            publishState(
                .connected,
                detail: "Connected to \(configuration.displayTarget) via shared local proxy \(endpoint.host):\(endpoint.port)"
            )
            requestBootstrapRemoteTTYIfNeededLocked()
            recordHeartbeatActivityLocked()
        case .error(let detail):
            debugLog("remote.proxy.error detail=\(detail) \(debugConfigSummary())")
            remotePortScanGeneration &+= 1
            remotePortScanBurstActive = false
            remotePortScanActiveReason = nil
            remotePortScanPendingReason = nil
            remotePortScanCoalesceWorkItem?.cancel()
            remotePortScanCoalesceWorkItem = nil
            remoteScannedPortsByPanel.removeAll()
            stopRemotePortPollingLocked()
            polledRemotePorts = []
            keepPolledRemotePortsUntilTTYScan = false
            proxyEndpoint = nil
            publishProxyEndpoint(nil)
            publishPortsSnapshotLocked()
            publishState(.error, detail: "Remote proxy to \(configuration.displayTarget) unavailable: \(detail)")
            failPendingPTYBridgeStartsLocked("remote daemon is not ready")
            guard Self.shouldEscalateProxyErrorToBootstrap(detail) else { return }

            proxyLease?.release()
            proxyLease = nil
            daemonReady = false
            daemonRemotePath = nil

            let retrySchedule = scheduleReconnectLocked(baseDelay: 2.0)
            let retrySuffix = Self.retrySuffix(retry: retrySchedule.retry, delay: retrySchedule.delay)
            publishDaemonStatus(
                .error,
                detail: "Remote daemon transport needs re-bootstrap after proxy failure\(retrySuffix)"
            )
        }
    }

    @discardableResult
    private func scheduleReconnectLocked(baseDelay: TimeInterval) -> RetrySchedule {
        let retryNumber = reconnectRetryCount + 1
        let retryDelay = Self.retryDelay(baseDelay: baseDelay, retry: retryNumber)
        guard !isStopping else { return RetrySchedule(retry: retryNumber, delay: retryDelay) }
        reconnectWorkItem?.cancel()
        reconnectRetryCount = retryNumber
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            guard !self.isStopping else { return }
            guard self.proxyLease == nil else { return }
            self.beginConnectionAttemptLocked()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + retryDelay, execute: workItem)
        return RetrySchedule(retry: retryNumber, delay: retryDelay)
    }

    private func publishState(_ state: WorkspaceRemoteConnectionState, detail: String?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteConnectionStateUpdate(
                state,
                detail: detail,
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    func publishDaemonStatus(
        _ state: WorkspaceRemoteDaemonState,
        detail: String?,
        version: String? = nil,
        name: String? = nil,
        capabilities: [String] = [],
        remotePath: String? = nil
    ) {
        let controllerID = self.controllerID
        let status = WorkspaceRemoteDaemonStatus(
            state: state,
            detail: detail,
            version: version,
            name: name,
            capabilities: capabilities,
            remotePath: remotePath
        )
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteDaemonStatusUpdate(
                status,
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    private func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteProxyEndpointUpdate(endpoint)
        }
    }

    func publishPortsSnapshotLocked() {
        let controllerID = self.controllerID
        let detectedByPanel = remotePortScanTTYNames.keys.reduce(into: [UUID: [Int]]()) { result, panelId in
            result[panelId] = remoteScannedPortsByPanel[panelId] ?? []
        }
        let detected = Array(
            Set(polledRemotePorts)
                .union(detectedByPanel.values.flatMap { $0 })
        ).sorted()
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteDetectedSurfacePortsSnapshot(
                detectedByPanel: detectedByPanel,
                detected: detected,
                forwarded: [],
                conflicts: [],
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    func recordHeartbeatActivityLocked() {
        heartbeatCount += 1
        publishHeartbeat(count: heartbeatCount, at: Date())
    }

    private func publishHeartbeat(count: Int, at date: Date?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteHeartbeatUpdate(count: count, lastSeenAt: date)
        }
    }

    private func requestBootstrapRemoteTTYIfNeededLocked() {
        guard !bootstrapRemoteTTYResolved else { return }
        guard let relayPort = configuration.relayPort, relayPort > 0 else { return }
        if !remotePortScanTTYNames.isEmpty {
            bootstrapRemoteTTYResolved = true
            bootstrapRemoteTTYRetryWorkItem?.cancel()
            bootstrapRemoteTTYRetryWorkItem = nil
            bootstrapRemoteTTYRetryCount = 0
            return
        }
        guard !bootstrapRemoteTTYFetchInFlight else { return }
        bootstrapRemoteTTYFetchInFlight = true
        defer { bootstrapRemoteTTYFetchInFlight = false }

        let command = "sh -c \(Self.shellSingleQuoted("tty_path=\"$HOME/.cmux/relay/\(relayPort).tty\"; if [ -r \"$tty_path\" ]; then cat \"$tty_path\"; fi"))"
        do {
            let result = try sshExec(
                arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command],
                timeout: 2
            )
            guard result.status == 0 else {
                scheduleBootstrapRemoteTTYRetryLocked()
                return
            }
            guard let ttyName = Self.normalizedRemotePortScanTTYName(result.stdout) else {
                scheduleBootstrapRemoteTTYRetryLocked()
                return
            }
            bootstrapRemoteTTYResolved = true
            bootstrapRemoteTTYRetryWorkItem?.cancel()
            bootstrapRemoteTTYRetryWorkItem = nil
            bootstrapRemoteTTYRetryCount = 0
            debugLog("remote.tty.bootstrap.ready tty=\(ttyName) \(debugConfigSummary())")
            publishBootstrapRemoteTTY(ttyName)
        } catch {
            debugLog("remote.tty.bootstrap.failed error=\(error.localizedDescription) \(debugConfigSummary())")
            scheduleBootstrapRemoteTTYRetryLocked()
        }
    }

    private func scheduleBootstrapRemoteTTYRetryLocked() {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard !bootstrapRemoteTTYResolved else { return }
        guard remotePortScanTTYNames.isEmpty else { return }
        guard bootstrapRemoteTTYRetryCount < Self.bootstrapRemoteTTYRetryLimit else { return }
        guard bootstrapRemoteTTYRetryWorkItem == nil else { return }

        bootstrapRemoteTTYRetryCount += 1
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.bootstrapRemoteTTYRetryWorkItem = nil
            self.requestBootstrapRemoteTTYIfNeededLocked()
        }
        bootstrapRemoteTTYRetryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.bootstrapRemoteTTYRetryDelay, execute: workItem)
    }

    private func publishBootstrapRemoteTTY(_ ttyName: String) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyBootstrapRemoteTTY(ttyName)
        }
    }

    private static let bootstrapRemoteTTYRetryDelay: TimeInterval = 0.5
    private static let bootstrapRemoteTTYRetryLimit = 8

    func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        cmuxDebugLog(message())
#endif
    }

    func debugConfigSummary() -> String {
        let controlPath = Self.debugSSHOptionValue(named: "ControlPath", in: configuration.sshOptions) ?? "nil"
        return
            "target=\(configuration.displayTarget) port=\(configuration.port.map(String.init) ?? "nil") " +
            "relayPort=\(configuration.relayPort.map(String.init) ?? "nil") " +
            "localSocket=\(configuration.localSocketPath ?? "nil") " +
            "controlPath=\(controlPath)"
    }

    func debugShellCommand(executable: String, arguments: [String]) -> String {
        ([URL(fileURLWithPath: executable).lastPathComponent] + arguments)
            .map(Self.shellSingleQuoted)
            .joined(separator: " ")
    }

    private static func debugSSHOptionValue(named key: String, in options: [String]) -> String? {
        let loweredKey = key.lowercased()
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == loweredKey {
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func debugLogSnippet(_ text: String, limit: Int = 160) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "\"\"" }
        if normalized.count <= limit {
            return normalized
        }
        return String(normalized.prefix(limit)) + "..."
    }

    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func retrySuffix(retry: Int, delay: TimeInterval) -> String {
        let seconds = max(1, Int(delay.rounded()))
        return " (retry \(retry) in \(seconds)s)"
    }

    static func retryDelay(baseDelay: TimeInterval, retry: Int) -> TimeInterval {
        let exponent = Double(max(0, retry - 1))
        return min(baseDelay * pow(2.0, exponent), 60.0)
    }

    private static func shouldEscalateProxyErrorToBootstrap(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("remote daemon transport failed")
            || lowered.contains("daemon transport closed stdout")
            || lowered.contains("daemon transport exited")
            || lowered.contains("daemon transport is not connected")
            || lowered.contains("daemon transport stopped")
    }

}
