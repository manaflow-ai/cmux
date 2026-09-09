import AppKit
import CmuxHive
import CmuxTerminal
import Foundation

/// Applies remote topology and terminal frames to this controller’s native mirrors.
extension HiveComputerMirrorController {
    /// Last remote grid dimensions applied to one mirror surface (closure
    /// state; a class so the frame handler can mutate its capture).
    private final class HiveMirrorAppliedDims {
        var columns = 0
        var rows = 0
    }

    /// Weak panel holder so closures passed INTO `addRemoteTmuxDisplayPane`
    /// (which creates the panel) can reference the created panel afterwards.
    private final class HiveMirrorPanelBox {
        weak var panel: TerminalPanel?
    }

    func reconcile(
        remote workspaces: [HiveRemoteWorkspace],
        mirror: HiveDeviceMirror,
        session: HiveRemoteMacSession
    ) {
        guard let tabManager = mirror.tabManager, session.client != nil else { return }

        let remoteIDs = Set(workspaces.map(\.id))
        // Remove mirrors whose remote workspace vanished (closed on host, or
        // the user closed the local mirror workspace themselves), and stop
        // their terminal streams so dead surface ids don't keep replaying.
        for (remoteID, workspaceId) in mirror.workspaceIdByRemoteID {
            let locallyClosed = tabManager.workspacesById[workspaceId] == nil
            guard locallyClosed || !remoteIDs.contains(remoteID) else { continue }
            mirror.workspaceIdByRemoteID.removeValue(forKey: remoteID)
            deviceIDByWorkspaceID.removeValue(forKey: workspaceId)
            for terminalID in mirror.terminalIDsByRemoteWorkspaceID[remoteID] ?? [] {
                mirror.terminalsByRemoteID.removeValue(forKey: terminalID)?.detach()
                mirror.panelIdByRemoteTerminalID.removeValue(forKey: terminalID)
            }
            mirror.terminalIDsByRemoteWorkspaceID.removeValue(forKey: remoteID)
            if let workspace = tabManager.workspacesById[workspaceId] {
                tabManager.closeWorkspace(workspace)
            }
        }
        // Prune terminals that vanished from surviving remote workspaces.
        for remote in workspaces {
            guard let workspaceId = mirror.workspaceIdByRemoteID[remote.id],
                  let workspace = tabManager.workspacesById[workspaceId] else { continue }
            let liveTerminalIDs = Set(remote.terminals.map(\.id))
            var kept: [String] = []
            for terminalID in mirror.terminalIDsByRemoteWorkspaceID[remote.id] ?? [] {
                if liveTerminalIDs.contains(terminalID) {
                    kept.append(terminalID)
                    continue
                }
                mirror.terminalsByRemoteID.removeValue(forKey: terminalID)?.detach()
                if let panelId = mirror.panelIdByRemoteTerminalID.removeValue(forKey: terminalID) {
                    _ = workspace.removeRemoteTmuxDisplayPane(panelId)
                }
            }
            mirror.terminalIDsByRemoteWorkspaceID[remote.id] = kept
        }

        for remote in workspaces {
            if let workspaceId = mirror.workspaceIdByRemoteID[remote.id],
               let workspace = tabManager.workspacesById[workspaceId] {
                deviceIDByWorkspaceID[workspaceId] = mirror.deviceID
                let nextWorkspaceTitle = localizedWorkspaceTitle(
                    remoteTitle: remote.title,
                    computerName: mirror.computerName
                )
                if workspace.title != nextWorkspaceTitle {
                    workspace.title = nextWorkspaceTitle
                }
                for terminal in remote.terminals {
                    if let panelID = mirror.panelIdByRemoteTerminalID[terminal.id] {
                        if workspace.panelTitle(panelId: panelID) != terminal.title {
                            workspace.updateRemoteTmuxTabTitle(panelId: panelID, title: terminal.title)
                        }
                    }
                }
                addMissingTerminals(remote: remote, workspace: workspace, mirror: mirror, session: session)
                continue
            }
            let title = localizedWorkspaceTitle(
                remoteTitle: remote.title,
                computerName: mirror.computerName
            )
            guard let workspace = tabManager.addWorkspaceIfActive(
                title: title,
                select: false,
                autoWelcomeIfNeeded: false,
                autoRefreshMetadata: false
            ) else { continue }
            // Reuses the remote-tmux mirror behavior set: manual-I/O display
            // tabs, restore exclusion, no local browser panes. Remote-tmux
            // command routing no-ops for this workspace (no tmux mirror is
            // registered for it).
            workspace.isRemoteTmuxMirror = true
            mirror.workspaceIdByRemoteID[remote.id] = workspace.id
            deviceIDByWorkspaceID[workspace.id] = mirror.deviceID
            let defaultPanelIds = Array(workspace.panels.keys)
            addMissingTerminals(remote: remote, workspace: workspace, mirror: mirror, session: session)
            for panelId in defaultPanelIds where workspace.panels[panelId] != nil {
                _ = workspace.removeRemoteTmuxDisplayPane(panelId)
            }
        }
        mirror.workspaceReadiness.publish(
            workspaces.lazy.compactMap { mirror.workspaceIdByRemoteID[$0.id] }.first
        )
    }

    /// Formats a mirror workspace title through the localized format resource
    /// so creation and later topology/title updates use identical text.
    private func localizedWorkspaceTitle(remoteTitle: String, computerName: String) -> String {
        let template = String(
            localized: "hive.mirror.workspaceTitle",
            defaultValue: "%1$@ — %2$@"
        )
        return String.localizedStringWithFormat(template, remoteTitle, computerName)
    }

    private func addMissingTerminals(
        remote: HiveRemoteWorkspace,
        workspace: Workspace,
        mirror: HiveDeviceMirror,
        session: HiveRemoteMacSession
    ) {
        for (index, terminal) in remote.terminals.enumerated()
        where mirror.terminalsByRemoteID[terminal.id] == nil {
            let remoteTerminalID = terminal.id
            guard let terminalSession = session.makeTerminalSession(
                workspaceID: remote.id,
                terminalID: terminal.id,
                retryDelay: { @Sendable attempt in
                    await HiveReconnectBackoff().delay(attempt: attempt)
                }
            ) else { continue }
            let panelBox = HiveMirrorPanelBox()
            guard let panel = workspace.addRemoteTmuxDisplayPane(
                remotePaneId: index,
                title: terminal.title,
                focus: false,
                onInput: { input in
                    guard case let .bytes(data) = input else { return }
                    let text = String(decoding: data, as: UTF8.self)
                    guard !text.isEmpty else { return }
                    Task { @MainActor in terminalSession.send(text: text) }
                },
                onResize: { [weak terminalSession] _, _ in
                    // A replay delivered to an unrealized/zero-sized manual
                    // surface renders nothing; repaint from the cached full
                    // frame immediately and re-request a fresh replay. The
                    // resize is also the first moment the view is laid out in
                    // its window, so kick the renderer here — a mirror window
                    // that never becomes key gets no focus event, and focus is
                    // otherwise the only path that starts the display link.
                    panelBox.panel?.surface.ensureRendererDrawing()
                    guard let terminalSession else { return }
                    if let cached = terminalSession.lastFullFrameBytes {
                        terminalSession.frameBytesHandler?(cached)
                    }
                    terminalSession.refreshReplay()
                },
                onClose: { [weak self, weak mirror, weak terminalSession] in
                    terminalSession?.detach()
                    guard let self, let mirror else { return }
                    self.handleClosedTerminal(terminalID: remoteTerminalID, mirror: mirror)
                }
            ) else { continue }
            panelBox.panel = panel
            // Font-fitted fill is disabled until the fit path supports
            // manual surfaces reliably (post-merge it produced blank panes);
            // the legacy cap renders at remote size, which always paints.
            panel.surface.manualIOFontFitEnabled = false
            // The remote grid is authoritative for the mirror surface's cell
            // dimensions; adopt them whenever they change so replay/patch rows
            // land on the layout they were produced for.
            let appliedDims = HiveMirrorAppliedDims()
            terminalSession.frameBytesHandler = { [weak panel, weak terminalSession] (bytes: Data) in
                guard let panel else { return }
                if let grid = terminalSession?.grid, grid.columns > 0, grid.rows > 0,
                   appliedDims.columns != grid.columns || appliedDims.rows != grid.rows {
                    appliedDims.columns = grid.columns
                    appliedDims.rows = grid.rows
                    _ = panel.surface.applyMobileViewportLimit(
                        columns: grid.columns,
                        rows: grid.rows,
                        reason: "hiveMirrorFrame"
                    )
                    // First frame (or a remote resize): make sure the renderer
                    // is actually producing frames — see onResize above.
                    panel.surface.ensureRendererDrawing()
                }
                guard !bytes.isEmpty else { return }
                panel.surface.processRemoteOutput(bytes)
            }
            terminalSession.attach()
            mirror.terminalsByRemoteID[terminal.id] = terminalSession
            mirror.panelIdByRemoteTerminalID[terminal.id] = panel.id
            mirror.terminalIDsByRemoteWorkspaceID[remote.id, default: []].append(terminal.id)
        }
    }

    private func handleClosedTerminal(terminalID: String, mirror: HiveDeviceMirror) {
        guard mirrorsByKey.values.contains(where: { $0 === mirror }) else { return }
        mirror.terminalsByRemoteID.removeValue(forKey: terminalID)?.detach()
        mirror.panelIdByRemoteTerminalID.removeValue(forKey: terminalID)
        for workspaceID in mirror.terminalIDsByRemoteWorkspaceID.keys {
            mirror.terminalIDsByRemoteWorkspaceID[workspaceID]?.removeAll { $0 == terminalID }
        }
    }
}
