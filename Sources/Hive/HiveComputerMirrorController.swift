import CmuxHive
import CmuxMobileRPC
import CmuxSettings
import CmuxTerminal
import Foundation

/// Presents a paired remote Mac's cmux workspaces as NATIVE local mirror
/// workspaces — the remote-tmux mirror recipe pointed at the hive RPC stream.
///
/// Each remote workspace becomes a real sidebar `Workspace` whose tabs are
/// manual-I/O ghostty surfaces: `HiveRemoteTerminalSession` streams
/// render-grid frames, `MobileTerminalRenderGridReplay` turns them into VT
/// bytes fed through `TerminalSurface.processRemoteOutput`, and typed input
/// returns over `mobile.terminal.input`. The result is the exact cmux UI —
/// sidebar rows, tab bar, pane chrome — backed by the other Mac's terminals.
///
/// Topology stays live: the controller consumes the session's
/// `workspaceUpdates()` stream and adds/removes mirror workspaces and
/// terminal tabs as the host's list changes.
@MainActor
final class HiveComputerMirrorController {
    static let shared = HiveComputerMirrorController()
    private init() {}

    private final class DeviceMirror {
        var computerName: String = ""
        weak var tabManager: TabManager?
        var reconcileTask: Task<Void, Never>?
        /// Local mirror workspace id per remote workspace id.
        var workspaceIdByRemoteID: [String: UUID] = [:]
        /// Terminal streams per remote terminal id.
        var terminalsByRemoteID: [String: HiveRemoteTerminalSession] = [:]
        /// Local display-tab panel id per remote terminal id.
        var panelIdByRemoteTerminalID: [String: UUID] = [:]
        /// Remote terminal ids per remote workspace id (repaint scoping and
        /// dead-terminal pruning).
        var terminalIDsByRemoteWorkspaceID: [String: [String]] = [:]
    }

    private var mirrorsByDeviceID: [String: DeviceMirror] = [:]

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

    /// Repaints a mirror workspace's terminals from their cached full frames
    /// and re-requests replays. Called when the workspace is selected so a
    /// surface that realized after its replay landed still paints. Scoped to
    /// the selected workspace's terminals only (a device-wide repaint storms
    /// replays on every click).
    func workspaceSelected(_ workspaceId: UUID) {
        for mirror in mirrorsByDeviceID.values {
            guard let remoteWorkspaceID = mirror.workspaceIdByRemoteID
                .first(where: { $0.value == workspaceId })?.key else { continue }
            let terminalIDs = mirror.terminalIDsByRemoteWorkspaceID[remoteWorkspaceID] ?? []
            for terminalID in terminalIDs {
                guard let terminal = mirror.terminalsByRemoteID[terminalID] else { continue }
                if let panelId = mirror.panelIdByRemoteTerminalID[terminalID],
                   let workspace = mirror.tabManager?.workspacesById[workspaceId],
                   let panel = workspace.panels[panelId] as? TerminalPanel {
                    panel.surface.ensureRendererDrawing()
                }
                if let cached = terminal.lastFullFrameBytes {
                    terminal.frameBytesHandler?(cached)
                }
                terminal.refreshReplay()
            }
            return
        }
    }

    /// The device a mirror workspace belongs to, or `nil` for local
    /// workspaces. Drives the sidebar's computer scope filter.
    func deviceID(forWorkspace workspaceId: UUID) -> String? {
        for (deviceID, mirror) in mirrorsByDeviceID
        where mirror.workspaceIdByRemoteID.values.contains(workspaceId) {
            return deviceID
        }
        return nil
    }

    /// Open a paired computer's viewer honoring the `computers.presentation`
    /// setting. This is the ONE shared action path behind every entrypoint
    /// (Settings "Open" button, sidebar scope picker, `hive.open` RPC):
    /// sidebar mode attaches mirrors into the key main window's sidebar;
    /// windows mode creates a real main window scoped to the device.
    static func presentViewer(deviceID: String) {
        Task { @MainActor in
            cmuxDebugLog("hive.presentViewer.begin device=\(deviceID.prefix(8))")
            let presentation: ComputersPresentationMode
            if let runtime = AppDelegate.shared?.settingsRuntime {
                presentation = await runtime.jsonStore.value(for: runtime.catalog.computers.presentation)
            } else {
                presentation = .windows
            }
            cmuxDebugLog("hive.presentViewer.mode \(presentation)")
            switch presentation {
            case .sidebar:
                guard let appDelegate = AppDelegate.shared,
                      let context = appDelegate.mainWindowContexts.values.first(where: { $0.window?.isKeyWindow == true })
                        ?? appDelegate.mainWindowContexts.values.first(where: { $0.window != nil })
                else {
                    HiveViewerWindowController.shared.show(deviceID: deviceID)
                    return
                }
                // Native mirrors: the computer's workspaces join the main
                // sidebar as real workspaces.
                context.sidebarSelectionState.selection = .tabs
                _ = await HiveComputerMirrorController.shared.attach(
                    deviceID: deviceID,
                    into: context.tabManager
                )
                context.window?.makeKeyAndOrderFront(nil)
            case .windows:
                // A real cmux window scoped to this computer: create a main
                // window, scope its sidebar to the device, attach mirrors.
                guard let appDelegate = AppDelegate.shared else { return }
                let windowId = appDelegate.createMainWindow(shouldActivate: true)
                var context = appDelegate.mainWindowContexts.values.first { $0.windowId == windowId }
                var attempts = 0
                while context == nil, attempts < 20 {
                    try? await Task.sleep(for: .milliseconds(100))
                    context = appDelegate.mainWindowContexts.values.first { $0.windowId == windowId }
                    attempts += 1
                }
                guard let context else {
                    cmuxDebugLog("hive.presentViewer.windowContextMissing windowId=\(windowId)")
                    return
                }
                HiveSidebarScopeModel.scopeModel(for: context.tabManager).scope = .device(deviceID)
                let attached = await HiveComputerMirrorController.shared.attach(
                    deviceID: deviceID,
                    into: context.tabManager
                )
                cmuxDebugLog("hive.presentViewer.attached workspace=\(attached?.uuidString.prefix(8) ?? "nil")")
            }
        }
    }

    /// Attaches (or re-focuses) a paired computer's workspaces as native
    /// mirror workspaces in `tabManager`, keeping them reconciled with the
    /// host's live topology.
    @discardableResult
    func attach(deviceID: String, into tabManager: TabManager) async -> UUID? {
        if let existing = mirrorsByDeviceID[deviceID] {
            if let firstId = existing.workspaceIdByRemoteID.values.first,
               let workspace = tabManager.workspacesById[firstId] {
                tabManager.selectWorkspace(workspace)
                return firstId
            }
            existing.reconcileTask?.cancel()
            mirrorsByDeviceID.removeValue(forKey: deviceID)
        }
        guard let session = await HiveComputersService.shared.embeddedSession(deviceID: deviceID) else {
            cmuxDebugLog("hive.mirror.attach.noSession device=\(deviceID.prefix(8))")
            return nil
        }
        let mirror = DeviceMirror()
        mirror.tabManager = tabManager
        mirror.computerName = HiveComputersService.shared.directory?.computers
            .first(where: { $0.deviceID == deviceID })?.displayName
            ?? session.displayName
        mirrorsByDeviceID[deviceID] = mirror

        mirror.reconcileTask = Task { @MainActor [weak self, weak mirror] in
            for await workspaces in session.workspaceUpdates() {
                guard let self, let mirror else { return }
                self.reconcile(remote: workspaces, mirror: mirror, session: session)
            }
        }

        // Wait briefly for the first non-empty list so the caller can select
        // a mirror workspace; reconciliation keeps running either way.
        var attempts = 0
        while mirror.workspaceIdByRemoteID.isEmpty, attempts < 40 {
            try? await Task.sleep(for: .milliseconds(250))
            attempts += 1
        }
        if let firstId = mirror.workspaceIdByRemoteID.values.first,
           let workspace = tabManager.workspacesById[firstId] {
            tabManager.selectWorkspace(workspace)
            return firstId
        }
        return nil
    }

    /// Detaches a computer's mirrors: stops the streams and closes the
    /// mirror workspaces.
    func detach(deviceID: String, from tabManager: TabManager) {
        guard let mirror = mirrorsByDeviceID.removeValue(forKey: deviceID) else { return }
        mirror.reconcileTask?.cancel()
        for (_, terminal) in mirror.terminalsByRemoteID { terminal.detach() }
        for (_, workspaceId) in mirror.workspaceIdByRemoteID {
            guard let workspace = tabManager.workspacesById[workspaceId] else { continue }
            tabManager.closeWorkspace(workspace)
        }
    }

    // MARK: - Reconcile

    private func reconcile(
        remote workspaces: [HiveRemoteWorkspace],
        mirror: DeviceMirror,
        session: HiveRemoteMacSession
    ) {
        guard let tabManager = mirror.tabManager, let client = session.client else { return }

        let remoteIDs = Set(workspaces.map(\.id))
        // Remove mirrors whose remote workspace vanished (closed on host, or
        // the user closed the local mirror workspace themselves), and stop
        // their terminal streams so dead surface ids don't keep replaying.
        for (remoteID, workspaceId) in mirror.workspaceIdByRemoteID {
            let locallyClosed = tabManager.workspacesById[workspaceId] == nil
            guard locallyClosed || !remoteIDs.contains(remoteID) else { continue }
            mirror.workspaceIdByRemoteID.removeValue(forKey: remoteID)
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
                addMissingTerminals(remote: remote, workspace: workspace, mirror: mirror, client: client)
                continue
            }
            let title = String(
                localized: "hive.mirror.workspaceTitle",
                defaultValue: "\(remote.title) — \(mirror.computerName)"
            )
            let workspace = tabManager.addWorkspace(
                title: title,
                select: false,
                autoWelcomeIfNeeded: false,
                autoRefreshMetadata: false
            )
            // Reuses the remote-tmux mirror behavior set: manual-I/O display
            // tabs, restore exclusion, no local browser panes. Remote-tmux
            // command routing no-ops for this workspace (no tmux mirror is
            // registered for it).
            workspace.isRemoteTmuxMirror = true
            mirror.workspaceIdByRemoteID[remote.id] = workspace.id
            let defaultPanelIds = Array(workspace.panels.keys)
            addMissingTerminals(remote: remote, workspace: workspace, mirror: mirror, client: client)
            for panelId in defaultPanelIds where workspace.panels[panelId] != nil {
                _ = workspace.removeRemoteTmuxDisplayPane(panelId)
            }
        }
    }

    private func addMissingTerminals(
        remote: HiveRemoteWorkspace,
        workspace: Workspace,
        mirror: DeviceMirror,
        client: MobileCoreRPCClient
    ) {
        for (index, terminal) in remote.terminals.enumerated()
        where mirror.terminalsByRemoteID[terminal.id] == nil {
            let terminalSession = HiveRemoteTerminalSession(
                client: client,
                workspaceID: remote.id,
                terminalID: terminal.id,
                retryDelay: { @Sendable attempt in
                    await HiveReconnectBackoff().delay(attempt: attempt)
                }
            )
            let panelBox = HiveMirrorPanelBox()
            guard let panel = workspace.addRemoteTmuxDisplayPane(
                remotePaneId: index,
                title: terminal.title,
                focus: false,
                onInput: { data in
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
}
