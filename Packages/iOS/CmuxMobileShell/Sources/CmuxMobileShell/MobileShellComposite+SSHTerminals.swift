public import CmuxMobileShellModel
import Foundation

/// Terminal tabs on SSH computers: "New Terminal" and pane geometry.
///
/// - tmux: a tab is a pane; New Terminal opens a tmux window.
/// - cmux-tui: New Terminal creates a terminal in the cmux-tui workspace.
/// - plain: one shell per workspace, so there are no terminal tabs.
@MainActor
extension MobileShellComposite {
    /// Whether "New Terminal" applies to this workspace row. `false` only
    /// for plain-shell SSH workspaces; Mac and other rows return `true`.
    public func sshSupportsTerminalTabs(workspaceID: MobileWorkspacePreview.ID) -> Bool {
        guard sshOwnsWorkspaceRow(workspaceID), let scoped = sshScopedWorkspaceID(workspaceID) else { return true }
        return sshComputers.supportsTerminalTabs(workspaceID: scoped)
    }

    /// The SSH branch of ``createTerminal(in:)``: creates the tab on the
    /// server, then selects it once the refreshed row lists it.
    func createSSHTerminal(in workspaceID: MobileWorkspacePreview.ID) {
        guard let scoped = sshScopedWorkspaceID(workspaceID),
              sshComputers.supportsTerminalTabs(workspaceID: scoped) else { return }
        selectedWorkspaceID = workspaceID
        Task { @MainActor [weak self] in
            guard let self, let terminal = await self.sshComputers.createTerminal(inWorkspace: scoped) else { return }
            let id = MobileTerminalPreview.ID(rawValue: terminal)
            // Rows are published before this returns; aggregation keeps SSH
            // terminal ids unscoped (they already carry the host namespace).
            guard self.workspaces.contains(where: { $0.terminals.contains { $0.id == id } }) else { return }
            self.selectedTerminalID = id
        }
    }

    /// The SSH-namespaced id of a workspace row (rows may be re-keyed by
    /// aggregation; the RPC id keeps the SSH scope).
    func sshScopedWorkspaceID(_ id: MobileWorkspacePreview.ID) -> String? {
        if MobileSSHIdentifiers.owns(id.rawValue) { return id.rawValue }
        guard let row = workspaces.first(where: { $0.id == id }),
              MobileSSHIdentifiers.owns(row.rpcWorkspaceID.rawValue) else { return nil }
        return row.rpcWorkspaceID.rawValue
    }

    // MARK: Pane geometry

    /// How SSH output sizes the surface: a tmux pane renders at its layout
    /// size (the surface pins to that grid and letterboxes); every other SSH
    /// surface uses the phone's own grid.
    func sshViewportPolicy(surfaceID: String) -> MobileTerminalOutputViewportPolicy {
        guard let grid = sshComputers.remoteGrid(surfaceID: surfaceID) else { return .natural }
        return .remoteGrid(columns: grid.columns, rows: grid.rows)
    }

    func sshApplyViewport(surfaceID: String) {
        _ = deliverTerminalOutput(
            TerminalOutputDelivery(
                bytes: Data(),
                replaceable: true,
                replacementScope: .viewportPolicy,
                viewportPolicy: sshViewportPolicy(surfaceID: surfaceID),
                requiresVerifiedReplay: false
            ),
            surfaceID: surfaceID,
            bypassReplayBarrier: true
        )
    }
}

@MainActor
extension MobileSSHComputers {
    /// Whether a workspace can gain terminal tabs (tmux, cmux-tui).
    func supportsTerminalTabs(workspaceID scopedID: String) -> Bool {
        guard let hostID = MobileSSHIdentifiers.hostID(of: scopedID) else { return false }
        switch host(id: hostID)?.persistence {
        case .tmux, .cmuxTUI: return true
        default: return false
        }
    }

    /// Creates a terminal tab in an SSH workspace and returns its scoped
    /// surface id after the host's rows are refreshed.
    func createTerminal(inWorkspace scopedID: String) async -> String? {
        guard let hostID = MobileSSHIdentifiers.hostID(of: scopedID),
              let local = MobileSSHIdentifiers.localID(of: scopedID) else { return nil }
        do {
            guard let creator = try await provider(for: hostID) as? any MobileSSHTerminalCreating else { return nil }
            let terminal = try await creator.createTerminal(inWorkspace: local)
            await refreshWorkspaces(hostID: hostID)
            return MobileSSHIdentifiers.scopedID(host: hostID, local: terminal.id)
        } catch {
            return nil
        }
    }
}
