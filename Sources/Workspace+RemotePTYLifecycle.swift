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


// MARK: - Remote PTY attach lifecycle and state updates
extension Workspace {
    func remotePTYSessionIDForSnapshot(panelId: UUID) -> String? {
        guard remoteConfiguration?.preserveAfterTerminalExit == true else {
            return nil
        }
        if let storedSessionID = normalizedRemotePTYSessionID(remotePTYSessionIDsByPanelId[panelId]) {
            return storedSessionID
        }
        guard activeRemoteTerminalSurfaceIds.contains(panelId) else {
            return nil
        }
        return Self.defaultSSHPTYSessionID(workspaceId: id, panelId: panelId)
    }

    nonisolated static func defaultSSHPTYSessionID(workspaceId: UUID, panelId: UUID) -> String {
        "ssh-\(workspaceId.uuidString)-\(panelId.uuidString)"
    }

    nonisolated static func parsedDefaultSSHPTYSessionID(_ value: String) -> (workspaceId: UUID, panelId: UUID)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ssh-") else { return nil }
        let suffix = String(trimmed.dropFirst(4))
        guard suffix.count == 73 else { return nil }
        let separatorIndex = suffix.index(suffix.startIndex, offsetBy: 36)
        guard suffix[separatorIndex] == "-" else { return nil }
        let panelStart = suffix.index(after: separatorIndex)
        let workspacePart = String(suffix[..<separatorIndex])
        let panelPart = String(suffix[panelStart...])
        guard let workspaceId = UUID(uuidString: workspacePart),
              let panelId = UUID(uuidString: panelPart) else {
            return nil
        }
        return (workspaceId, panelId)
    }

    nonisolated static func sshPTYAttachStartupCommand(sessionID: String) -> String {
        SSHPTYAttachStartupCommandBuilder.command(sessionID: sessionID)
    }

    func remotePTYAttachStartupCommand(sessionID: String) -> String {
        guard let remoteConfiguration,
              remoteConfiguration.preserveAfterTerminalExit,
              let foregroundAuthToken = remoteConfiguration.foregroundAuthToken else {
            return Self.sshPTYAttachStartupCommand(sessionID: sessionID)
        }
        let foregroundAuth = SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
            destination: remoteConfiguration.destination,
            port: remoteConfiguration.port,
            identityFile: remoteConfiguration.identityFile,
            sshOptions: remoteConfiguration.sshOptions,
            token: foregroundAuthToken
        )
        return SSHPTYAttachStartupCommandBuilder.command(
            sessionID: sessionID,
            foregroundAuth: foregroundAuth
        )
    }

    func discardRemotePTYSessionID(panelId: UUID) {
        remotePTYSessionIDsByPanelId.removeValue(forKey: panelId)
        endedPersistentRemotePTYAttachSurfaceIds.remove(panelId)
        removeRemoteRelaySurfaceAliases(targeting: panelId)
    }

    func remotePTYSessionIDMatches(panelId: UUID, sessionID: String?) -> Bool {
        guard activeRemoteTerminalSurfaceIds.contains(panelId),
              let normalizedSessionID = normalizedRemotePTYSessionID(sessionID) else {
            return false
        }
        let expectedSessionID = normalizedRemotePTYSessionID(remotePTYSessionIDsByPanelId[panelId])
            ?? Self.defaultSSHPTYSessionID(workspaceId: id, panelId: panelId)
        return normalizedSessionID == expectedSessionID
    }

    @discardableResult
    func markRemotePTYAttachEnded(surfaceId: UUID, sessionID: String) -> (clearedRemotePTYSession: Bool, untrackedRemoteTerminal: Bool) {
        let normalizedSessionID = normalizedRemotePTYSessionID(sessionID)
        let expectedSessionID = normalizedRemotePTYSessionID(remotePTYSessionIDsByPanelId[surfaceId])
            ?? Self.defaultSSHPTYSessionID(workspaceId: id, panelId: surfaceId)
        guard let normalizedSessionID, normalizedSessionID == expectedSessionID else {
            return (false, false)
        }

        let wasTracked = activeRemoteTerminalSurfaceIds.contains(surfaceId)
        if remoteConfiguration?.preserveAfterTerminalExit == true {
            endedPersistentRemotePTYAttachSurfaceIds.insert(surfaceId)
        } else {
            endedPersistentRemotePTYAttachSurfaceIds.remove(surfaceId)
        }
        remotePTYSessionIDsByPanelId.removeValue(forKey: surfaceId)
        removeRemoteRelaySurfaceAliases(targeting: surfaceId)
        untrackRemoteTerminalSurface(surfaceId)
        return (true, wasTracked)
    }

    func markPersistentRemotePTYAttachFailed(surfaceId: UUID) {
        guard remoteConfiguration?.preserveAfterTerminalExit == true else { return }

        remotePTYSessionIDsByPanelId.removeValue(forKey: surfaceId)
        endedPersistentRemotePTYAttachSurfaceIds.remove(surfaceId)
        removeRemoteRelaySurfaceAliases(targeting: surfaceId)
        pendingRemoteTerminalChildExitSurfaceIds.remove(surfaceId)
        transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: surfaceId)
        surfaceTTYNames.removeValue(forKey: surfaceId)
        if activeRemoteTerminalSurfaceIds.remove(surfaceId) != nil {
            activeRemoteTerminalSessionCount = activeRemoteTerminalSurfaceIds.count
        }
        syncRemotePortScanTTYs()
        applyBrowserRemoteWorkspaceStatusToPanels()
    }

    func maybeDemoteRemoteWorkspaceAfterSSHSessionEnded() {
        guard activeRemoteTerminalSurfaceIds.isEmpty, remoteConfiguration != nil else { return }
        if remoteConfiguration?.preserveAfterTerminalExit == true {
            return
        }
        let hasBrowserPanels = panels.values.contains { $0 is BrowserPanel }
        if !hasBrowserPanels {
            if remoteConnectionState == .error ||
                remoteDaemonStatus.state == .error ||
                remoteConnectionState == .connecting ||
                remoteConnectionState == .reconnecting {
                return
            }
            disconnectRemoteConnection(clearConfiguration: true)
        }
    }

    @MainActor
    func rememberPendingRemoteSurfaceTTY(_ ttyName: String, requestedSurfaceId: UUID?) {
        let trimmedTTY = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTTY.isEmpty else { return }
        pendingRemoteSurfaceTTYName = trimmedTTY
        pendingRemoteSurfaceTTYSurfaceId = requestedSurfaceId
    }

    @MainActor
    func rememberPendingRemoteSurfacePortKick(
        reason: WorkspaceRemoteSessionController.PortScanKickReason,
        requestedSurfaceId: UUID?
    ) {
        pendingRemoteSurfacePortKickReason = reason
        pendingRemoteSurfacePortKickSurfaceId = requestedSurfaceId
    }

    @MainActor
    func applyPendingRemoteSurfaceTTYIfNeeded(to panelId: UUID) {
        guard let ttyName = pendingRemoteSurfaceTTYName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ttyName.isEmpty else {
            return
        }
        if let requestedSurfaceId = pendingRemoteSurfaceTTYSurfaceId, requestedSurfaceId != panelId {
            return
        }
        surfaceTTYNames[panelId] = ttyName
        pendingRemoteSurfaceTTYName = nil
        pendingRemoteSurfaceTTYSurfaceId = nil
        syncRemotePortScanTTYs()
        if !applyPendingRemoteSurfacePortKickIfNeeded(to: panelId) {
            kickRemotePortScan(panelId: panelId, reason: .command)
        }
    }

    @MainActor
    @discardableResult
    func applyPendingRemoteSurfacePortKickIfNeeded(to panelId: UUID) -> Bool {
        guard let reason = pendingRemoteSurfacePortKickReason else {
            return false
        }
        if let requestedSurfaceId = pendingRemoteSurfacePortKickSurfaceId,
           requestedSurfaceId != panelId {
            return false
        }
        guard let ttyName = surfaceTTYNames[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ttyName.isEmpty else {
            return false
        }
        _ = ttyName
        pendingRemoteSurfacePortKickReason = nil
        pendingRemoteSurfacePortKickSurfaceId = nil
        kickRemotePortScan(panelId: panelId, reason: reason)
        return true
    }

    @MainActor
    func applyBootstrapRemoteTTY(_ ttyName: String) {
        let trimmedTTY = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTTY.isEmpty else { return }

        let candidateSurfaceId: UUID? = {
            if let focusedPanelId, activeRemoteTerminalSurfaceIds.contains(focusedPanelId) {
                return focusedPanelId
            }
            if activeRemoteTerminalSurfaceIds.count == 1 {
                return activeRemoteTerminalSurfaceIds.first
            }
            return nil
        }()

        guard let candidateSurfaceId else {
            rememberPendingRemoteSurfaceTTY(trimmedTTY, requestedSurfaceId: nil)
            return
        }

        surfaceTTYNames[candidateSurfaceId] = trimmedTTY
        syncRemotePortScanTTYs()
        if !applyPendingRemoteSurfacePortKickIfNeeded(to: candidateSurfaceId) {
            kickRemotePortScan(panelId: candidateSurfaceId, reason: .command)
        }
    }

    private func cleanupTransferredRemoteConnectionIfNeeded(surfaceId: UUID, relayPort: Int?) -> Bool {
        guard let relayPort,
              relayPort > 0,
              let cleanupConfiguration = transferredRemoteCleanupConfigurationsByPanelId[surfaceId],
              cleanupConfiguration.relayPort == relayPort else {
            return false
        }
        transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: surfaceId)
        Self.requestSSHControlMasterCleanupIfNeeded(configuration: cleanupConfiguration)
        return true
    }

    func markRemoteTerminalSessionEnded(surfaceId: UUID, relayPort: Int?) {
        if cleanupTransferredRemoteConnectionIfNeeded(surfaceId: surfaceId, relayPort: relayPort) {
            return
        }
        guard let relayPort,
              relayPort > 0,
              remoteConfiguration?.relayPort == relayPort else {
            return
        }
        // Arm the replacement-banner before ownership of `remoteConfiguration` drains
        // away through `untrackRemoteTerminalSurface` → `disconnectRemoteConnection`.
        // The banner only matters if we end up demoting this workspace to local, so
        // `createReplacementTerminalPanel` consumes and clears the value.
        if remoteConfiguration?.preserveAfterTerminalExit != true,
           let displayTarget = remoteConfiguration?.displayTarget {
            pendingReplacementBannerRemoteTarget = displayTarget
        }
        pendingRemoteTerminalChildExitSurfaceIds.insert(surfaceId)
        untrackRemoteTerminalSurface(surfaceId)
    }

    func teardownRemoteConnection() {
        disconnectRemoteConnection(clearConfiguration: true)
    }

    static func requestSSHControlMasterCleanupIfNeeded(configuration: WorkspaceRemoteConfiguration) {
        guard let arguments = sshControlMasterCleanupArguments(configuration: configuration) else { return }
        if let override = runSSHControlMasterCommandOverrideForTesting {
            override(arguments)
            return
        }

        sshControlMasterCleanupQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            process.environment = configuration.sshProcessEnvironment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let exitSemaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in
                exitSemaphore.signal()
            }

            do {
                try process.run()
                if exitSemaphore.wait(timeout: .now() + 5) == .timedOut {
                    if process.isRunning {
                        process.terminate()
                    }
                    _ = exitSemaphore.wait(timeout: .now() + 1)
                }
            } catch {
                return
            }
        }
    }

    private static func sshControlMasterCleanupArguments(configuration: WorkspaceRemoteConfiguration) -> [String]? {
        let sshOptions = normalizedSSHControlCleanupOptions(configuration.sshOptions)
        var arguments: [String] = [
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
        ]
        if let port = configuration.port {
            arguments += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines),
           !identityFile.isEmpty {
            arguments += ["-i", identityFile]
        }
        for option in sshOptions {
            arguments += ["-o", option]
        }
        arguments += ["-O", "exit", configuration.destination]
        return arguments
    }

    private static func normalizedSSHControlCleanupOptions(_ options: [String]) -> [String] {
        let disallowedKeys: Set<String> = ["controlmaster", "controlpersist"]
        return options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let key = sshOptionKeyForControlCleanup(trimmed) else { return nil }
            return disallowedKeys.contains(key) ? nil : trimmed
        }
    }

    private static func sshOptionKeyForControlCleanup(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    func applyRemoteConnectionStateUpdate(
        _ state: WorkspaceRemoteConnectionState,
        detail: String?,
        target: String
    ) {
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxyOnlyError = trimmedDetail.map(Self.isProxyOnlyRemoteError) ?? false
        let preserveConnectedStateForRetry =
            (state == .connecting || state == .reconnecting) &&
                preservesSSHTerminalConnection &&
                hasProxyOnlyRemoteSidebarError
        let effectiveState: WorkspaceRemoteConnectionState
        if state == .error && proxyOnlyError && preservesSSHTerminalConnection {
            effectiveState = .connected
        } else if preserveConnectedStateForRetry {
            effectiveState = .connected
        } else {
            effectiveState = state
        }

        remoteConnectionState = effectiveState
        remoteConnectionDetail = detail
        applyBrowserRemoteWorkspaceStatusToPanels()

        if let trimmedDetail, !trimmedDetail.isEmpty, (state == .error || proxyOnlyError) {
            let statusPrefix = proxyOnlyError ? "Remote proxy unavailable" : "SSH error"
            let statusIcon = proxyOnlyError ? "exclamationmark.triangle.fill" : "network.slash"
            let notificationTitle = proxyOnlyError ? "Remote Proxy Unavailable" : "Remote SSH Error"
            let logSource = proxyOnlyError ? "remote-proxy" : "remote"
            statusEntries[Self.remoteErrorStatusKey] = SidebarStatusEntry(
                key: Self.remoteErrorStatusKey,
                value: "\(statusPrefix) (\(target)): \(trimmedDetail)",
                icon: statusIcon,
                color: nil,
                timestamp: Date()
            )

            let fingerprint = "connection:\(trimmedDetail)"
            if remoteLastErrorFingerprint != fingerprint {
                remoteLastErrorFingerprint = fingerprint
                appendSidebarLog(
                    message: "\(statusPrefix) (\(target)): \(trimmedDetail)",
                    level: .error,
                    source: logSource
                )
                AppDelegate.shared?.notificationStore?.addNotification(
                    tabId: id,
                    surfaceId: nil,
                    title: notificationTitle,
                    subtitle: target,
                    body: trimmedDetail,
                    cooldownKey: remoteNotificationCooldownKey(target: target),
                    cooldownInterval: Self.remoteNotificationCooldown
                )
            }
            return
        }

        if state == .connected {
            statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
            remoteLastErrorFingerprint = nil
        }
    }

    func applyRemoteDaemonStatusUpdate(_ status: WorkspaceRemoteDaemonStatus, target: String) {
        remoteDaemonStatus = status
        applyBrowserRemoteWorkspaceStatusToPanels()
        guard status.state == .error else {
            remoteLastDaemonErrorFingerprint = nil
            return
        }
        let trimmedDetail = status.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "remote daemon error"
        let fingerprint = "daemon:\(trimmedDetail)"
        guard remoteLastDaemonErrorFingerprint != fingerprint else { return }
        remoteLastDaemonErrorFingerprint = fingerprint
        appendSidebarLog(
            message: "Remote daemon error (\(target)): \(trimmedDetail)",
            level: .error,
            source: "remote-daemon"
        )
    }

    func applyRemoteProxyEndpointUpdate(_ endpoint: BrowserProxyEndpoint?) {
        remoteProxyEndpoint = endpoint
        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            browserPanel.setRemoteProxyEndpoint(endpoint)
        }
        applyBrowserRemoteWorkspaceStatusToPanels()
    }

    func applyRemoteHeartbeatUpdate(count: Int, lastSeenAt: Date?) {
        remoteHeartbeatCount = max(0, count)
        remoteLastHeartbeatAt = lastSeenAt
        applyBrowserRemoteWorkspaceStatusToPanels()
    }

    func applyRemoteDetectedSurfacePortsSnapshot(
        detectedByPanel: [UUID: [Int]],
        detected: [Int],
        forwarded: [Int],
        conflicts: [Int],
        target: String
    ) {
        let trackedSurfaceIds = Set(detectedByPanel.keys)
        for panelId in remoteDetectedSurfaceIds.subtracting(trackedSurfaceIds) {
            surfaceListeningPorts.removeValue(forKey: panelId)
        }
        remoteDetectedSurfaceIds = trackedSurfaceIds

        for (panelId, ports) in detectedByPanel {
            if ports.isEmpty {
                surfaceListeningPorts.removeValue(forKey: panelId)
            } else {
                surfaceListeningPorts[panelId] = ports
            }
        }

        remoteDetectedPorts = detected
        remoteForwardedPorts = forwarded
        remotePortConflicts = conflicts
        recomputeListeningPorts()

        if conflicts.isEmpty {
            statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
            remoteLastPortConflictFingerprint = nil
            return
        }

        let conflictsList = conflicts.map { ":\($0)" }.joined(separator: ", ")
        statusEntries[Self.remotePortConflictStatusKey] = SidebarStatusEntry(
            key: Self.remotePortConflictStatusKey,
            value: "SSH port conflicts (\(target)): \(conflictsList)",
            icon: "exclamationmark.triangle.fill",
            color: nil,
            timestamp: Date()
        )

        let fingerprint = conflicts.map(String.init).joined(separator: ",")
        guard remoteLastPortConflictFingerprint != fingerprint else { return }
        remoteLastPortConflictFingerprint = fingerprint
        appendSidebarLog(
            message: "Port conflicts while forwarding \(target): \(conflictsList)",
            level: .warning,
            source: "remote-forward"
        )
    }

    func clearRemoteDetectedSurfacePorts() {
        for panelId in remoteDetectedSurfaceIds {
            surfaceListeningPorts.removeValue(forKey: panelId)
        }
        remoteDetectedSurfaceIds.removeAll()
    }

    /// Writes a small shell wrapper that prints a banner ("remote ssh ended — target X"),
    /// then execs the user's `$SHELL`. Returned path goes to `initialCommand`, which Ghostty
    /// runs as the PTY command. The banner survives as text in scrollback so the user can
    /// see it after the replacement local shell starts.
    private static func replacementShellScriptWithBanner(target: String) -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent(
            "cmux-remote-disconnect-banner-\(UUID().uuidString.lowercased()).sh"
        )
        // Encode the target as base64 and decode it inside the shell. This sidesteps every
        // layer of shell quoting: no matter what the target contains (`$(id)`, backticks,
        // single/double quotes, escape sequences), the shell never sees it as shell syntax.
        // Previous version only escaped backslash and double-quote, which left command
        // substitution and backticks as a live injection vector (Codex P2).
        let encodedTarget = Data(target.utf8).base64EncodedString()
        // Localized banner strings. Both use %s (not %@) because they're rendered by the
        // POSIX printf inside the shell wrapper, not by Swift's String(format:).
        let endedLineFormat = String(
            localized: "remote.disconnectBanner.sessionEnded",
            defaultValue: "[cmux] remote ssh session ended: %s"
        )
        let reconnectLine = String(
            localized: "remote.disconnectBanner.reconnectHint",
            defaultValue: "[cmux] falling back to a local shell. Reconnect with the original cmux ssh or cmux vm attach command."
        )
        // Encode the localized lines the same way as the target, so a translator using
        // backticks or $(…) in a translation string can't unexpectedly execute in the
        // user's local shell. Decoded inline at wrapper startup, then fed to printf.
        let encodedEndedFormat = Data(endedLineFormat.utf8).base64EncodedString()
        let encodedReconnectLine = Data(reconnectLine.utf8).base64EncodedString()
        let body = """
        #!/bin/sh
        cmux_disconnect_decode() {
          printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null
        }
        cmux_disconnect_target="$(cmux_disconnect_decode '\(encodedTarget)')"
        cmux_disconnect_ended_format="$(cmux_disconnect_decode '\(encodedEndedFormat)')"
        cmux_disconnect_reconnect_line="$(cmux_disconnect_decode '\(encodedReconnectLine)')"
        # Append newline + color codes ourselves rather than trusting the translator to
        # preserve them in every locale.
        printf '\\033[1;33m'
        printf "$cmux_disconnect_ended_format" "$cmux_disconnect_target"
        printf '\\033[0m\\n' >&2
        printf '\\033[2m%s\\033[0m\\n' "$cmux_disconnect_reconnect_line" >&2
        printf '\\n'
        unset cmux_disconnect_target cmux_disconnect_ended_format cmux_disconnect_reconnect_line
        unset -f cmux_disconnect_decode 2>/dev/null || true
        # Remove ourselves so /tmp doesn't accumulate these wrappers across sessions.
        rm -f -- "$0" 2>/dev/null || true
        exec "${SHELL:-/bin/sh}" -l

        """
        do {
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return scriptURL.path
        } catch {
            return "/bin/sh"
        }
    }

    /// Create a new terminal panel (used when replacing the last panel)
    @discardableResult
    func createReplacementTerminalPanel() -> TerminalPanel {
        let inheritedConfig = inheritedTerminalConfig(
            preferredPanelId: focusedPanelId,
            inPane: bonsplitController.focusedPaneId
        )
        // If the previous surface was a remote ssh terminal that just exited, spawn a
        // local shell that first prints a clearly-coloured banner explaining what happened.
        // Without this banner a dead VM surfaces as an ordinary local `lawrence@mac ~ %`
        // prompt, which looks identical to "I never connected" and was mis-read during
        // dogfood as "cmux disconnected silently".
        let bannerTarget = pendingReplacementBannerRemoteTarget
        pendingReplacementBannerRemoteTarget = nil
        let replacementInitialCommand: String? = bannerTarget.map { Self.replacementShellScriptWithBanner(target: $0) }
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: inheritedConfig,
            portOrdinal: portOrdinal,
            initialCommand: replacementInitialCommand
        )
        configureNewTerminalPanel(newPanel)
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)

        // Create tab in bonsplit
        if let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false
        ) {
            surfaceIdToPanelId[newTabId] = newPanel.id
        }

        return newPanel
    }

}
