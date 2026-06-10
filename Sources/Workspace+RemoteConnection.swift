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


// MARK: - Remote connection management
extension Workspace {
    nonisolated static let remoteDaemonManifestInfoKey = WorkspaceRemoteSessionController.remoteDaemonManifestInfoKey

    nonisolated static func remoteDaemonManifest(from infoDictionary: [String: Any]?) -> WorkspaceRemoteDaemonManifest? {
        WorkspaceRemoteSessionController.remoteDaemonManifest(from: infoDictionary)
    }

    nonisolated static func remoteDaemonCachedBinaryURL(
        version: String,
        goOS: String,
        goArch: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try WorkspaceRemoteSessionController.remoteDaemonCachedBinaryURL(
            version: version,
            goOS: goOS,
            goArch: goArch,
            fileManager: fileManager
        )
    }

    static func isProxyOnlyRemoteError(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("remote proxy")
            || lowered.contains("proxy_unavailable")
            || lowered.contains("local daemon proxy")
            || lowered.contains("proxy failure")
            || lowered.contains("daemon transport")
    }

    var preservesSSHTerminalConnection: Bool {
        activeRemoteTerminalSessionCount > 0
            && remoteConfiguration?.terminalStartupCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var hasProxyOnlyRemoteSidebarError: Bool {
        guard let entry = statusEntries[Self.remoteErrorStatusKey]?.value else { return false }
        return entry.lowercased().contains("remote proxy unavailable")
    }

    func remoteNotificationCooldownKey(target: String) -> String? {
        let rawTarget = (remoteConfiguration?.destination ?? target)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTarget.isEmpty else { return nil }
        let normalizedHost = rawTarget
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalizedHost, !normalizedHost.isEmpty else { return nil }
        return "remote-host:\(normalizedHost)"
    }

    var isRemoteWorkspace: Bool {
        remoteConfiguration != nil
    }

    var isRestorableInSessionSnapshot: Bool {
        guard let remoteConfiguration else { return true }
        return remoteConfiguration.sessionSnapshot() != nil
    }

    @MainActor
    func isRemoteTerminalSurface(_ panelId: UUID) -> Bool {
        activeRemoteTerminalSurfaceIds.contains(panelId)
    }

    @MainActor
    func shouldKeepPersistentRemoteSurfaceOpenAfterChildExit(_ panelId: UUID) -> Bool {
        guard remoteConfiguration?.preserveAfterTerminalExit == true else { return false }
        return activeRemoteTerminalSurfaceIds.contains(panelId) ||
            endedPersistentRemotePTYAttachSurfaceIds.contains(panelId)
    }

    @MainActor
    func shouldDemoteWorkspaceAfterChildExit(surfaceId: UUID) -> Bool {
        isRemoteWorkspace || pendingRemoteTerminalChildExitSurfaceIds.contains(surfaceId)
    }

    var remoteDisplayTarget: String? {
        remoteConfiguration?.displayTarget
    }

    var hasActiveRemoteTerminalSessions: Bool {
        activeRemoteTerminalSessionCount > 0
    }

    @MainActor
    func uploadDroppedFilesForRemoteTerminal(
        _ fileURLs: [URL],
        operation: TerminalImageTransferOperation,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        guard let controller = remoteSessionController else {
            completion(.failure(RemoteDropUploadError.unavailable))
            return
        }
        controller.uploadDroppedFiles(fileURLs, operation: operation, completion: completion)
    }

    @MainActor
    func uploadDroppedFilesForRemoteTerminal(
        _ fileURLs: [URL],
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        uploadDroppedFilesForRemoteTerminal(
            fileURLs,
            operation: TerminalImageTransferOperation(),
            completion: completion
        )
    }

    func syncRemotePortScanTTYs() {
        guard isRemoteWorkspace else { return }
        remoteSessionController?.updateRemotePortScanTTYs(surfaceTTYNames)
    }

    func remotePTYSessionControllerForSocketCommand() -> WorkspaceRemoteSessionController? {
        remoteSessionController
    }

    func kickRemotePortScan(panelId: UUID, reason: WorkspaceRemoteSessionController.PortScanKickReason = .command) {
        guard isRemoteWorkspace else { return }
        syncRemotePortScanTTYs()
        remoteSessionController?.kickRemotePortScan(panelId: panelId, reason: reason)
    }

    func listRemotePTYSessions() throws -> [[String: Any]] {
        guard let controller = remoteSessionController else {
            throw NSError(domain: "cmux.remote.pty", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        return try controller.listPTYSessions()
    }

    func closeRemotePTYSession(sessionID: String) throws {
        guard let controller = remoteSessionController else {
            throw NSError(domain: "cmux.remote.pty", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        try controller.closePTYSession(sessionID: sessionID)
    }

    func startRemotePTYBridge(
        sessionID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool
    ) throws -> WorkspaceRemotePTYBridgeServer.Endpoint {
        guard let controller = remoteSessionController else {
            throw NSError(domain: "cmux.remote.pty", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        return try controller.startPTYBridge(
            sessionID: sessionID,
            attachmentID: attachmentID,
            command: command,
            requireExisting: requireExisting
        )
    }

    func resizeRemotePTY(sessionID: String, attachmentID: String, attachmentToken: String, cols: Int, rows: Int) throws {
        guard let controller = remoteSessionController else {
            throw NSError(domain: "cmux.remote.pty", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        try controller.resizePTY(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken,
            cols: cols,
            rows: rows
        )
    }

    func detachRemotePTYAttachment(sessionID: String, attachmentID: String, attachmentToken: String) throws {
        guard let controller = remoteSessionController else {
            throw NSError(domain: "cmux.remote.pty", code: 14, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        try controller.detachPTYSession(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken
        )
    }

    func remoteStatusPayload() -> [String: Any] {
        let heartbeatAgeSeconds: Any = {
            guard let last = remoteLastHeartbeatAt else { return NSNull() }
            return max(0, Date().timeIntervalSince(last))
        }()
        let heartbeatTimestamp: Any = {
            guard let last = remoteLastHeartbeatAt else { return NSNull() }
            return Self.remoteHeartbeatDateFormatter.string(from: last)
        }()
        var payload: [String: Any] = [
            "enabled": remoteConfiguration != nil,
            "state": remoteConnectionState.rawValue,
            "connected": remoteConnectionState == .connected,
            "active_terminal_sessions": activeRemoteTerminalSessionCount,
            "daemon": remoteDaemonStatus.payload(),
            "detected_ports": remoteDetectedPorts,
            "forwarded_ports": remoteForwardedPorts,
            "conflicted_ports": remotePortConflicts,
            "detail": remoteConnectionDetail ?? NSNull(),
            "heartbeat": [
                "count": remoteHeartbeatCount,
                "last_seen_at": heartbeatTimestamp,
                "age_seconds": heartbeatAgeSeconds,
            ],
        ]
        if let endpoint = remoteProxyEndpoint {
            payload["proxy"] = [
                "state": "ready",
                "host": endpoint.host,
                "port": endpoint.port,
                "schemes": ["socks5", "http_connect"],
                "url": "socks5://\(endpoint.host):\(endpoint.port)",
            ]
        } else {
            let proxyState: String
            if hasProxyOnlyRemoteSidebarError {
                proxyState = "error"
            } else {
                switch remoteConnectionState {
                case .connecting, .reconnecting:
                    proxyState = "connecting"
                case .error:
                    proxyState = "error"
                default:
                    proxyState = "unavailable"
                }
            }
            payload["proxy"] = [
                "state": proxyState,
                "host": NSNull(),
                "port": NSNull(),
                "schemes": ["socks5", "http_connect"],
                "url": NSNull(),
                "error_code": proxyState == "error" ? "proxy_unavailable" : NSNull(),
            ]
        }
        if let remoteConfiguration {
            payload["transport"] = remoteConfiguration.transport.rawValue
            payload["destination"] = remoteConfiguration.destination
            payload["port"] = remoteConfiguration.port ?? NSNull()
            payload["has_identity_file"] = remoteConfiguration.identityFile != nil
            payload["has_ssh_options"] = !remoteConfiguration.sshOptions.isEmpty
            payload["local_proxy_port"] = remoteConfiguration.localProxyPort ?? NSNull()
            payload["persistent_daemon_slot"] = remoteConfiguration.persistentDaemonSlot ?? NSNull()
        } else {
            payload["transport"] = NSNull()
            payload["destination"] = NSNull()
            payload["port"] = NSNull()
            payload["has_identity_file"] = false
            payload["has_ssh_options"] = false
            payload["local_proxy_port"] = NSNull()
            payload["persistent_daemon_slot"] = NSNull()
        }
        return payload
    }

    func configureRemoteConnection(_ configuration: WorkspaceRemoteConfiguration, autoConnect: Bool = true) {
        defer { TerminalController.shared.notifyRemotePTYControllerAvailabilityChanged() }
        let previousConfiguration = remoteConfiguration
        skipControlMasterCleanupAfterDetachedRemoteTransfer = false
        if let previousConfiguration,
           previousConfiguration != configuration,
           !previousConfiguration.hasSamePersistentPTYIdentity(as: configuration) {
            remotePTYSessionIDsByPanelId.removeAll()
            endedPersistentRemotePTYAttachSurfaceIds.removeAll()
            clearRemoteRelayIDAliases()
        }
        remoteConfiguration = configuration
        seedInitialRemoteTerminalSessionIfNeeded(configuration: configuration)
        clearRemoteDetectedSurfacePorts()
        remoteDetectedPorts = []
        remoteForwardedPorts = []
        remotePortConflicts = []
        remoteProxyEndpoint = nil
        remoteHeartbeatCount = 0
        remoteLastHeartbeatAt = nil
        remoteConnectionDetail = nil
        remoteDaemonStatus = WorkspaceRemoteDaemonStatus()
        statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
        statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
        remoteLastErrorFingerprint = nil
        remoteLastDaemonErrorFingerprint = nil
        remoteLastPortConflictFingerprint = nil
        recomputeListeningPorts()

        let previousController = remoteSessionController
        activeRemoteSessionControllerID = nil
        remoteSessionController = nil
        previousController?.stop()
        applyRemoteProxyEndpointUpdate(nil)
        applyBrowserRemoteWorkspaceStatusToPanels()

        let foregroundAuthToken = Self.normalizedForegroundAuthToken(configuration.foregroundAuthToken)
        let shouldAutoConnect =
            autoConnect
            || (foregroundAuthToken != nil && foregroundAuthToken == pendingRemoteForegroundAuthToken)
        pendingRemoteForegroundAuthToken = nil
        if configuration.transport == .websocket,
           configuration.daemonWebSocketEndpoint == nil {
            remoteConnectionState = .connected
            applyBrowserRemoteWorkspaceStatusToPanels()
            return
        }
        guard shouldAutoConnect else {
            remoteConnectionState = .disconnected
            applyBrowserRemoteWorkspaceStatusToPanels()
            return
        }

        remoteConnectionState = .connecting
        applyBrowserRemoteWorkspaceStatusToPanels()
        let controllerID = UUID()
        let controller = WorkspaceRemoteSessionController(
            workspace: self,
            configuration: configuration,
            controllerID: controllerID
        )
        activeRemoteSessionControllerID = controllerID
        remoteSessionController = controller
        syncRemotePortScanTTYs()
        syncRemoteRelayIDAliasesToController()
        controller.start()
    }

    func reconnectRemoteConnection() {
        guard let configuration = remoteConfiguration else { return }
        configureRemoteConnection(configuration, autoConnect: true)
    }

    private static func normalizedForegroundAuthToken(_ token: String?) -> String? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func notifyRemoteForegroundAuthenticationReady(token: String? = nil) {
        guard let foregroundAuthToken = Self.normalizedForegroundAuthToken(token) else {
            return
        }

        guard let remoteConfiguration else {
            pendingRemoteForegroundAuthToken = foregroundAuthToken
            return
        }

        guard Self.normalizedForegroundAuthToken(remoteConfiguration.foregroundAuthToken) == foregroundAuthToken else {
            return
        }

        pendingRemoteForegroundAuthToken = nil
        guard remoteConnectionState == .disconnected else { return }
        reconnectRemoteConnection()
    }

    func disconnectRemoteConnection(clearConfiguration: Bool = false) {
        defer { TerminalController.shared.notifyRemotePTYControllerAvailabilityChanged() }
        let shouldCleanupControlMaster =
            clearConfiguration
            && !isDetachingCloseTransaction
            && pendingDetachedSurfaces.isEmpty
            && !skipControlMasterCleanupAfterDetachedRemoteTransfer
        let configurationForCleanup = shouldCleanupControlMaster ? remoteConfiguration : nil
        let previousController = remoteSessionController
        activeRemoteSessionControllerID = nil
        remoteSessionController = nil
        previousController?.stop()
        pendingRemoteForegroundAuthToken = nil
        activeRemoteTerminalSurfaceIds.removeAll()
        endedPersistentRemotePTYAttachSurfaceIds.removeAll()
        activeRemoteTerminalSessionCount = 0
        pendingRemoteSurfaceTTYName = nil
        pendingRemoteSurfaceTTYSurfaceId = nil
        pendingRemoteSurfacePortKickReason = nil
        pendingRemoteSurfacePortKickSurfaceId = nil
        clearRemoteDetectedSurfacePorts()
        remoteDetectedPorts = []
        remoteForwardedPorts = []
        remotePortConflicts = []
        remoteProxyEndpoint = nil
        remoteHeartbeatCount = 0
        remoteLastHeartbeatAt = nil
        remoteConnectionState = .disconnected
        remoteConnectionDetail = nil
        remoteDaemonStatus = WorkspaceRemoteDaemonStatus()
        statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
        statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
        remoteLastErrorFingerprint = nil
        remoteLastDaemonErrorFingerprint = nil
        remoteLastPortConflictFingerprint = nil
        if clearConfiguration {
            remotePTYSessionIDsByPanelId.removeAll()
            endedPersistentRemotePTYAttachSurfaceIds.removeAll()
            clearRemoteRelayIDAliases()
            remoteConfiguration = nil
            skipControlMasterCleanupAfterDetachedRemoteTransfer = false
        }
        applyRemoteProxyEndpointUpdate(nil)
        applyBrowserRemoteWorkspaceStatusToPanels()
        recomputeListeningPorts()
        if let configurationForCleanup {
            Self.requestSSHControlMasterCleanupIfNeeded(configuration: configurationForCleanup)
        }
    }

    func clearRemoteConfigurationIfWorkspaceBecameLocal() {
        guard !isDetachingCloseTransaction, panels.isEmpty, remoteConfiguration != nil else { return }
        if remoteConfiguration?.preserveAfterTerminalExit == true {
            return
        }
        disconnectRemoteConnection(clearConfiguration: true)
    }

    private func seedInitialRemoteTerminalSessionIfNeeded(configuration: WorkspaceRemoteConfiguration) {
        guard configuration.terminalStartupCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        guard activeRemoteTerminalSurfaceIds.isEmpty else { return }
        let terminalIds = panels.compactMap { panelId, panel in
            panel is TerminalPanel ? panelId : nil
        }
        guard terminalIds.count == 1, let initialPanelId = terminalIds.first else { return }
        trackRemoteTerminalSurface(initialPanelId)
    }

    func trackRemoteTerminalSurface(_ panelId: UUID) {
        skipControlMasterCleanupAfterDetachedRemoteTransfer = false
        endedPersistentRemotePTYAttachSurfaceIds.remove(panelId)
        pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
        transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: panelId)
        if remoteConfiguration?.preserveAfterTerminalExit == true,
           normalizedRemotePTYSessionID(remotePTYSessionIDsByPanelId[panelId]) == nil {
            remotePTYSessionIDsByPanelId[panelId] = Self.defaultSSHPTYSessionID(workspaceId: id, panelId: panelId)
        }
        guard activeRemoteTerminalSurfaceIds.insert(panelId).inserted else { return }
        activeRemoteTerminalSessionCount = activeRemoteTerminalSurfaceIds.count
        applyPendingRemoteSurfaceTTYIfNeeded(to: panelId)
        _ = applyPendingRemoteSurfacePortKickIfNeeded(to: panelId)
    }

    func untrackRemoteTerminalSurface(_ panelId: UUID) {
        guard activeRemoteTerminalSurfaceIds.remove(panelId) != nil else { return }
        activeRemoteTerminalSessionCount = activeRemoteTerminalSurfaceIds.count
        guard !isDetachingCloseTransaction else { return }
        maybeDemoteRemoteWorkspaceAfterSSHSessionEnded()
    }

    func terminalStartupEnvironment(
        base: [String: String],
        remoteStartupCommand: String?
    ) -> [String: String] {
        guard remoteStartupCommand != nil,
              let remoteEnvironment = remoteConfiguration?.sshTerminalStartupEnvironment else {
            return base
        }
        var environment = base
        for (key, value) in remoteEnvironment {
            environment[key] = value
        }
        return environment
    }

    func normalizedRemotePTYSessionID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

}
