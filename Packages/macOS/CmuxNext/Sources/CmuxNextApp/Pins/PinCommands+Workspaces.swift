import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

/// Workspace pins and top rows through the one pin path
/// (PINNED-ITEMS-END-TO-END P2, P4): the palette, the row and tile menus,
/// drag commits, the CLI and MCP call these. While the layout accepts
/// edits (the store serves `sidebar-layout-v1`, or the DEV prototype), a
/// pin is a workspace tile in `sec_pinned`; before that it is the legacy
/// `workspace-pin-v1` flag, today's path. A user's change is an undo step
/// whose inverse is computed from the layout it changed, so undo puts a
/// tile back with its id at its place; automation adds no undo step.
extension PinCommands {
    private var layout: SidebarLayoutService { context.services.sidebarLayout }
    private var refs: WorkspaceLayoutRefs { WorkspaceLayoutRefs(machines: context.services.machines) }

    /// Pins are layout tiles (not the legacy flag).
    var pinsAreTiles: Bool { layout.unavailableReason == nil }

    /// Whether `workspace` shows pinned, in the model the sidebar draws.
    func isWorkspacePinned(_ workspace: WorkspaceModel) -> Bool {
        guard pinsAreTiles else { return workspace.pinned }
        return refs.ref(forWorkspace: workspace.id).map(layout.document.isPinned) ?? false
    }

    /// Pins or unpins sidebar workspace `id`. Throws the refusal (no
    /// layout ref for the workspace, the owner refuses, or no pin
    /// capability on its daemon).
    func setWorkspacePinned(_ id: String, pinned: Bool, origin: ActionOrigin) throws {
        if pinsAreTiles {
            guard let ref = refs.ref(forWorkspace: id) else { throw ActionFailure(message: PinStrings.workspaceCannotPin) }
            let document = layout.document
            let label: String? = nil // red: the name is not stored yet
            guard let op = pinned ? document.pinOp(ref, label: label) : document.unpinOp(ref) else { return }
            return try sendLayout(op, title: pinned ? PinStrings.pinWorkspace : PinStrings.unpinWorkspace, origin: origin)
        }
        try setLegacyPinned(id, pinned: pinned)
        guard origin == .user else { return }
        registerUndo(title: pinned ? PinStrings.pinWorkspace : PinStrings.unpinWorkspace) { commands in
            try? commands.setWorkspacePinned(id, pinned: !pinned, origin: .user)
        }
    }

    /// Whether sidebar workspace `id` shows in the top rows (not as a tile).
    func isWorkspaceOnTopRows(_ id: String) -> Bool { false }

    /// Red: not implemented yet.
    func toggleWorkspaceOnTop(_ id: String, origin: ActionOrigin) throws {}

    /// Sends one layout change and, for the user, registers its inverse.
    func sendLayout(_ op: SidebarLayoutOp, title: String, origin: ActionOrigin) throws {
        let inverse = layout.document.inverse(of: op)
        try layout.send(op)
        guard origin == .user, let inverse else { return }
        registerUndo(title: title) { commands in
            do { try commands.sendLayout(inverse, title: title, origin: .user) } catch {
                commands.context.services.registry.refuse(String(describing: error))
            }
        }
    }

    /// The legacy flag through the window's sidebar (optimistic row move),
    /// else straight to the owning daemon.
    private func setLegacyPinned(_ id: String, pinned: Bool) throws {
        guard let (workspace, daemon) = context.services.machines.workspace(id: id) else {
            throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn)
        }
        guard daemon.supports(DaemonCapabilities.shared.workspacePin) else {
            throw ActionFailure(message: daemon.missingCapabilityMessage(DaemonCapabilities.shared.workspacePin))
        }
        if let sidebar = context.activeWindow?.sidebar {
            sidebar.handle(.setPinned([SidebarWorkspaceID(workspace.id)], pinned))
        } else if let key = workspace.key {
            daemon.send("set-workspace-metadata") { _ = try await $0.setWorkspaceMetadata(key, pinned: pinned) }
        }
    }
}
