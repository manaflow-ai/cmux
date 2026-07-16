import CmuxHive
import CmuxMobileRPC
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
    }

    private var mirrorsByDeviceID: [String: DeviceMirror] = [:]

    /// Last remote grid dimensions applied to one mirror surface (closure
    /// state; a class so the frame handler can mutate its capture).
    private final class HiveMirrorAppliedDims {
        var columns = 0
        var rows = 0
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
        // the user closed the local mirror workspace themselves).
        for (remoteID, workspaceId) in mirror.workspaceIdByRemoteID {
            let locallyClosed = tabManager.workspacesById[workspaceId] == nil
            guard locallyClosed || !remoteIDs.contains(remoteID) else { continue }
            mirror.workspaceIdByRemoteID.removeValue(forKey: remoteID)
            if let workspace = tabManager.workspacesById[workspaceId] {
                tabManager.closeWorkspace(workspace)
            }
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
                    // A replay delivered to a zero-sized manual surface renders
                    // nothing; re-request one whenever the surface (re)sizes so
                    // the first visible layout always paints a full frame.
                    terminalSession?.refreshReplay()
                }
            ) else { continue }
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
                }
                guard !bytes.isEmpty else { return }
                panel.surface.processRemoteOutput(bytes)
            }
            terminalSession.attach()
            mirror.terminalsByRemoteID[terminal.id] = terminalSession
            mirror.panelIdByRemoteTerminalID[terminal.id] = panel.id
        }
    }
}
