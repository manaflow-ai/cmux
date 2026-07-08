import Foundation
import CmuxCore

extension Workspace {
    /// Returns whether the configured remote should be inherited.
    ///
    /// Pane-scope membership includes tracked remote terminal surfaces and
    /// remote-scoped browser panels.
    func remoteInheritanceAllows(_ policy: WorkspaceRemoteInheritance) -> Bool {
        guard let scope = remoteConfiguration?.scope else { return false }
        return scope.allowsInheritance(
            policy: policy,
            isSourcePaneRemote: {
                activeRemoteTerminalSurfaceIds.contains($0) ||
                    remoteScopedBrowserPanelIds.contains($0)
            }
        )
    }

    func remoteTerminalStartupCommand(inheritance policy: WorkspaceRemoteInheritance) -> String? {
        remoteInheritanceAllows(policy) ? remoteTerminalStartupCommand() : nil
    }

    func syncRemoteTabIndicator(panelId: UUID) {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        let showsRemoteIndicator =
            remoteConfiguration?.scope == .pane &&
            activeRemoteTerminalSurfaceIds.contains(panelId)
        bonsplitController.updateTab(tabId, showsRemoteIndicator: showsRemoteIndicator)
    }

    func canDisconnectRemoteSurface(panelId: UUID) -> Bool {
        remoteConfiguration?.scope == .pane &&
            activeRemoteTerminalSurfaceIds.contains(panelId)
    }

    func disconnectRemoteSurface(panelId: UUID) {
        guard canDisconnectRemoteSurface(panelId: panelId) else { return }
        let target = remoteConfiguration?.displayTarget ?? "remote host"
        if remoteSessionController != nil {
            let sessionID = normalizedRemotePTYSessionID(remotePTYSessionIDsByPanelId[panelId])
                ?? Self.defaultSSHPTYSessionID(workspaceId: id, panelId: panelId)
            do {
                try closeRemotePTYSession(sessionID: sessionID)
            } catch {
#if DEBUG
                cmuxDebugLog(
                    "remote.disconnectSurface.closePTYFailed workspace=\(id.uuidString.prefix(5)) " +
                    "panel=\(panelId.uuidString.prefix(5)) error=\(String(describing: error))"
                )
#endif
            }
        }

        discardRemotePTYSessionID(panelId: panelId)
        removeRemoteRelaySurfaceAliases(targeting: panelId)
        untrackRemoteTerminalSurface(panelId)

        let message = "[cmux] Disconnected from \(target). This pane is now a local shell."
        let script = "printf '%s\\n' \(Self.shellQuote(message)); exec \"${SHELL:-/bin/zsh}\" -l"
        _ = respawnTerminalSurface(
            panelId: panelId,
            command: "/bin/sh -c \(Self.shellQuote(script))",
            waitAfterCommand: false
        )
        syncRemoteTabIndicator(panelId: panelId)
    }

    func joinPaneScopedRemoteConnection(seedPanelId: UUID) -> String? {
        guard remoteConfiguration?.scope == .pane,
              terminalPanel(for: seedPanelId) != nil,
              let command = remoteTerminalStartupCommand() else {
            return nil
        }
        trackRemoteTerminalSurface(seedPanelId)
        return command
    }

    func remoteTerminalStartupCommand() -> String? {
        guard !suppressRemoteTerminalStartupForSessionRestoreScaffold else {
            return nil
        }
        guard let command = effectiveRemoteTerminalStartupCommand(from: remoteConfiguration),
              !command.isEmpty else {
            return nil
        }
        return command
    }

    func browserRemoteWorkspaceStatusSnapshot() -> BrowserRemoteWorkspaceStatus? {
        guard let target = remoteDisplayTarget else { return nil }
        return BrowserRemoteWorkspaceStatus(
            target: target,
            connectionState: remoteConnectionState,
            heartbeatCount: remoteHeartbeatCount,
            lastHeartbeatAt: remoteLastHeartbeatAt
        )
    }

    func applyBrowserRemoteWorkspaceStatusToPanels() {
        let snapshot = browserRemoteWorkspaceStatusSnapshot()
        let paneScoped = remoteConfiguration?.scope == .pane
        for (panelId, panel) in panels {
            let panelSnapshot = paneScoped && !remoteScopedBrowserPanelIds.contains(panelId) ? nil : snapshot
            (panel as? BrowserPanel)?.setRemoteWorkspaceStatus(panelSnapshot)
        }
        _dockSplit?.applyRemoteWorkspaceStatus(paneScoped ? nil : snapshot)
    }

    func applyRemoteProxyEndpointUpdate(_ endpoint: BrowserProxyEndpoint?) {
        remoteProxyEndpoint = endpoint
        let paneScoped = remoteConfiguration?.scope == .pane
        for (panelId, panel) in panels {
            let panelEndpoint = paneScoped && !remoteScopedBrowserPanelIds.contains(panelId) ? nil : endpoint
            (panel as? BrowserPanel)?.setRemoteProxyEndpoint(panelEndpoint)
        }
        _dockSplit?.applyRemoteProxyEndpointUpdate(paneScoped ? nil : endpoint)
        applyBrowserRemoteWorkspaceStatusToPanels()
    }

    func maybeDemoteRemoteWorkspaceAfterSSHSessionEnded() {
        guard activeRemoteTerminalSurfaceIds.isEmpty, remoteConfiguration != nil else { return }
        if remoteConfiguration?.preserveAfterTerminalExit == true {
            return
        }
        let hasBrowserPanels = remoteConfiguration?.scope == .pane
            ? !remoteScopedBrowserPanelIds.isEmpty
            : panels.values.contains { $0 is BrowserPanel }
        if !hasBrowserPanels {
            if remoteConnectionState == .error ||
                remoteDaemonStatus.state == .error ||
                remoteConnectionState == .connecting ||
                remoteConnectionState == .reconnecting ||
                remoteConnectionState == .suspended {
                return
            }
            disconnectRemoteConnection(clearConfiguration: true)
        }
    }

    func seedInitialRemoteTerminalSessionIfNeeded(configuration: WorkspaceRemoteConfiguration) {
        guard configuration.terminalStartupCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        guard activeRemoteTerminalSurfaceIds.isEmpty else { return }
        let terminalIds = panels.compactMap { panelId, panel in
            panel is TerminalPanel && !remoteDisconnectPlaceholderPanelIds.contains(panelId)
                ? panelId
                : nil
        }
        if terminalIds.count == 1, let initialPanelId = terminalIds.first {
            trackRemoteTerminalSurface(initialPanelId)
            return
        }
        if let focusedPanelId, terminalIds.contains(focusedPanelId) {
            trackRemoteTerminalSurface(focusedPanelId)
        }
    }
}
