internal import CmuxMobileRPC
internal import CmuxMobileShellModel
internal import CmuxMobileSupport
import Observation

/// Workspace/terminal list state carved out of ``MobileShellComposite``.
///
/// Owns the workspace list, the selected workspace/terminal, selection
/// reconciliation when the list changes, local preview creation, and
/// `applyRemoteWorkspaceList` with per-terminal snapshot preservation. It
/// performs no I/O: the facade decodes RPC responses and hands them to this
/// model, passing connection-side inputs (the active ticket's target) as
/// plain values so the model never reaches back into connection state.
@MainActor
@Observable
final class MobileWorkspaceModel {
    var workspaces: [MobileWorkspacePreview]
    var selectedWorkspaceID: MobileWorkspacePreview.ID? {
        didSet {
            syncSelectedTerminalForWorkspace()
        }
    }
    var selectedTerminalID: MobileTerminalPreview.ID?

    init(workspaces: [MobileWorkspacePreview]) {
        self.workspaces = workspaces
        self.selectedWorkspaceID = workspaces.first?.id
        self.selectedTerminalID = workspaces.first?.terminals.first?.id
    }

    var selectedWorkspace: MobileWorkspacePreview? {
        guard let selectedWorkspaceID else {
            return workspaces.first
        }
        return workspaces.first { $0.id == selectedWorkspaceID } ?? workspaces.first
    }

    var selectedTerminal: MobileTerminalPreview? {
        guard let selectedWorkspace else {
            return nil
        }
        if let selectedTerminalID,
           let terminal = selectedWorkspace.terminals.first(where: { $0.id == selectedTerminalID }) {
            return terminal
        }
        return selectedWorkspace.preferredTerminal
    }

    func setSelectedWorkspaceID(_ id: MobileWorkspacePreview.ID?) {
        selectedWorkspaceID = id
    }

    /// Reconcile the selected terminal after the workspace list or selection
    /// changed: keep a still-present ready selection (or any selection while
    /// the workspace has no ready terminal), otherwise fall back to the
    /// workspace's preferred terminal.
    func syncSelectedTerminalForWorkspace() {
        guard let selectedWorkspace else {
            selectedTerminalID = nil
            return
        }
        if let selectedTerminalID,
           let selectedTerminal = selectedWorkspace.terminals.first(where: { $0.id == selectedTerminalID }),
           selectedTerminal.isReady || !selectedWorkspace.hasReadyTerminal {
            return
        }
        selectedTerminalID = selectedWorkspace.preferredTerminal?.id
    }

    /// Resolves the workspace that owns a terminal surface.
    func workspaceID(forTerminalID terminalID: String) -> MobileWorkspacePreview.ID? {
        for workspace in workspaces {
            if workspace.terminals.contains(where: { $0.id.rawValue == terminalID }) {
                return workspace.id
            }
        }
        return nil
    }

    /// Appends and selects a local preview workspace (no remote connection).
    func appendLocalWorkspace() {
        let nextIndex = workspaces.count + 1
        let workspace = MobileWorkspacePreview(
            id: .init(rawValue: "workspace-\(nextIndex)"),
            name: L10n.workspaceName(index: nextIndex),
            terminals: [
                MobileTerminalPreview(
                    id: .init(rawValue: "workspace-\(nextIndex)-terminal-1"),
                    name: L10n.terminalName(index: 1)
                ),
            ]
        )
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        selectedTerminalID = workspace.terminals.first?.id
    }

    /// Appends and selects a local preview terminal in the selected workspace.
    func appendLocalTerminal() {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == selectedWorkspace?.id }) else {
            return
        }
        let terminalIndex = workspaces[workspaceIndex].terminals.count + 1
        let terminal = MobileTerminalPreview(
            id: .init(rawValue: "\(workspaces[workspaceIndex].id.rawValue)-terminal-\(terminalIndex)"),
            name: L10n.terminalName(index: terminalIndex)
        )
        workspaces[workspaceIndex].terminals.append(terminal)
        selectedTerminalID = terminal.id
    }

    /// Replaces the workspace list with the ticket's single attached
    /// workspace/terminal (preview mode without a sync runtime).
    func applyPreviewTicket(workspaceID: String, terminalID ticketTerminalID: String?) {
        let terminalID = ticketTerminalID ?? "attached-terminal"
        workspaces = [
            MobileWorkspacePreview(
                id: .init(rawValue: workspaceID),
                name: L10n.string("mobile.preview.attachedWorkspaceName", defaultValue: "Attached Workspace"),
                terminals: [
                    MobileTerminalPreview(
                        id: .init(rawValue: terminalID),
                        name: L10n.string("mobile.preview.attachedTerminalName", defaultValue: "Attached Terminal")
                    ),
                ]
            ),
        ]
        selectedWorkspaceID = workspaces.first?.id
        selectedTerminalID = workspaces.first?.terminals.first?.id
    }

    /// Applies a remote workspace list, preserving per-terminal local
    /// snapshot state (viewport fit) and reconciling selection.
    ///
    /// - Parameters:
    ///   - response: The decoded `workspace.list` (or create) response.
    ///   - preferActiveTicketTarget: When `true`, selection jumps to the
    ///     attach ticket's workspace/terminal if present in the new list.
    ///   - mergeExistingWorkspaces: When `true`, the new list merges into the
    ///     existing one by id instead of replacing it (scoped create
    ///     responses that only carry the affected workspace).
    ///   - activeTicketWorkspaceID: The active attach ticket's workspace id,
    ///     supplied by the facade.
    ///   - activeTicketTerminalID: The active attach ticket's terminal id,
    ///     supplied by the facade.
    func applyRemoteWorkspaceList(
        _ response: MobileSyncWorkspaceListResponse,
        preferActiveTicketTarget: Bool = false,
        mergeExistingWorkspaces: Bool = false,
        activeTicketWorkspaceID: String? = nil,
        activeTicketTerminalID: String? = nil
    ) {
        let remoteWorkspaces = remoteWorkspacesPreservingSnapshots(from: response)
        if mergeExistingWorkspaces {
            var mergedWorkspaces = workspaces
            for remoteWorkspace in remoteWorkspaces {
                if let existingIndex = mergedWorkspaces.firstIndex(where: { $0.id == remoteWorkspace.id }) {
                    mergedWorkspaces[existingIndex] = remoteWorkspace
                } else {
                    mergedWorkspaces.append(remoteWorkspace)
                }
            }
            workspaces = mergedWorkspaces
        } else {
            workspaces = remoteWorkspaces
        }
        if preferActiveTicketTarget,
           selectActiveTicketTargetIfAvailable(
               workspaceID: activeTicketWorkspaceID,
               terminalID: activeTicketTerminalID
           ) {
            return
        }
        if let selectedWorkspaceID,
           workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            syncSelectedTerminalForWorkspace()
            return
        }
        setSelectedWorkspaceID(
            response.workspaces.first(where: \.isSelected)
                .map { MobileWorkspacePreview.ID(rawValue: $0.id) }
                ?? workspaces.first?.id
        )
        syncSelectedTerminalForWorkspace()
    }

    private func remoteWorkspacesPreservingSnapshots(
        from response: MobileSyncWorkspaceListResponse
    ) -> [MobileWorkspacePreview] {
        response.workspaces.map { remoteWorkspace in
            var workspace = MobileWorkspacePreview(remote: remoteWorkspace)
            guard let existingWorkspace = workspaces.first(where: { $0.id == workspace.id }) else {
                return workspace
            }
            workspace.terminals = workspace.terminals.map { remoteTerminal in
                guard let existingTerminal = existingWorkspace.terminals.first(where: { $0.id == remoteTerminal.id }) else {
                    return remoteTerminal
                }
                var terminal = remoteTerminal
                terminal.viewportFit = existingTerminal.viewportFit
                return terminal
            }
            return workspace
        }
    }

    private func selectActiveTicketTargetIfAvailable(
        workspaceID: String?,
        terminalID: String?
    ) -> Bool {
        guard let workspaceID else {
            return false
        }
        let ticketWorkspaceID = MobileWorkspacePreview.ID(rawValue: workspaceID)
        guard let workspace = workspaces.first(where: { $0.id == ticketWorkspaceID }) else {
            return false
        }
        setSelectedWorkspaceID(ticketWorkspaceID)
        if let ticketTerminalID = terminalID.map(MobileTerminalPreview.ID.init(rawValue:)),
           workspace.terminals.contains(where: { $0.id == ticketTerminalID }) {
            selectedTerminalID = ticketTerminalID
        } else {
            syncSelectedTerminalForWorkspace()
        }
        return true
    }
}

private extension MobileWorkspacePreview {
    /// The terminal selection falls back to when the current selection is
    /// missing or not ready: ready+focused first, then ready, then focused,
    /// then the first terminal.
    var preferredTerminal: MobileTerminalPreview? {
        terminals.first { $0.isReady && $0.isFocused }
            ?? terminals.first { $0.isReady }
            ?? terminals.first { $0.isFocused }
            ?? terminals.first
    }

    /// Whether any terminal in the workspace is ready.
    var hasReadyTerminal: Bool {
        terminals.contains(where: \.isReady)
    }
}
