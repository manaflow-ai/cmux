import CmuxHive
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
/// v1 scope: the remote topology is snapshotted at attach (one workspace per
/// remote workspace, one tab per remote terminal); live topology reconcile
/// and remote workspace/tab creation are follow-ups.
@MainActor
final class HiveComputerMirrorController {
    static let shared = HiveComputerMirrorController()
    private init() {}

    private struct DeviceMirror {
        var workspaceIds: [UUID] = []
        var terminals: [HiveRemoteTerminalSession] = []
    }

    private var mirrorsByDeviceID: [String: DeviceMirror] = [:]

    /// Whether `workspaceId` is one of this controller's mirror workspaces.
    func ownsWorkspace(_ workspaceId: UUID) -> Bool {
        mirrorsByDeviceID.values.contains { $0.workspaceIds.contains(workspaceId) }
    }

    /// Attaches (or re-focuses) a paired computer's workspaces as native
    /// mirror workspaces in `tabManager`.
    /// - Returns: the first mirror workspace id, or `nil` when the session
    ///   could not be created or the computer reported no workspaces.
    @discardableResult
    func attach(deviceID: String, into tabManager: TabManager) async -> UUID? {
        if let existing = mirrorsByDeviceID[deviceID],
           let firstId = existing.workspaceIds.first,
           let workspace = tabManager.workspacesById[firstId] {
            tabManager.selectWorkspace(workspace)
            return firstId
        }
        guard let session = await HiveComputersService.shared.embeddedSession(deviceID: deviceID),
              let client = session.client else { return nil }
        // The session connects asynchronously; wait briefly for the first
        // workspace list rather than mirroring an empty snapshot.
        var attempts = 0
        while session.workspaces.isEmpty, attempts < 40 {
            try? await Task.sleep(for: .milliseconds(250))
            attempts += 1
        }
        let remoteWorkspaces = session.workspaces
        guard !remoteWorkspaces.isEmpty else { return nil }
        let computerName = HiveComputersService.shared.directory?.computers
            .first(where: { $0.deviceID == deviceID })?.displayName
            ?? session.displayName

        var mirror = DeviceMirror()
        for remote in remoteWorkspaces {
            let title = String(
                localized: "hive.mirror.workspaceTitle",
                defaultValue: "\(remote.title) — \(computerName)"
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
            let defaultPanelIds = Array(workspace.panels.keys)

            for (index, terminal) in remote.terminals.enumerated() {
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
                    }
                ) else { continue }
                terminalSession.frameBytesHandler = { [weak panel] bytes in
                    guard !bytes.isEmpty else { return }
                    panel?.surface.processRemoteOutput(bytes)
                }
                terminalSession.attach()
                mirror.terminals.append(terminalSession)
            }

            // Drop the workspace's default local shell tab; the mirror tabs
            // are the workspace now (same move as the tmux mirror).
            for panelId in defaultPanelIds where workspace.panels[panelId] != nil {
                _ = workspace.removeRemoteTmuxDisplayPane(panelId)
            }
            mirror.workspaceIds.append(workspace.id)
        }
        guard !mirror.workspaceIds.isEmpty else { return nil }
        mirrorsByDeviceID[deviceID] = mirror
        if let firstId = mirror.workspaceIds.first,
           let workspace = tabManager.workspacesById[firstId] {
            tabManager.selectWorkspace(workspace)
        }
        return mirror.workspaceIds.first
    }

    /// Detaches a computer's mirrors: stops the terminal streams and closes
    /// the mirror workspaces.
    func detach(deviceID: String, from tabManager: TabManager) {
        guard let mirror = mirrorsByDeviceID.removeValue(forKey: deviceID) else { return }
        for terminal in mirror.terminals { terminal.detach() }
        for workspaceId in mirror.workspaceIds {
            guard let workspace = tabManager.workspacesById[workspaceId] else { continue }
            tabManager.closeWorkspace(workspace)
        }
    }
}
