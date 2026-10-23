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
    var pinsAreTiles: Bool { SidebarDocWiring.layoutUnavailableReason(layout) == nil }

    /// Whether `workspace` shows pinned, in the model the sidebar draws.
    func isWorkspacePinned(_ workspace: WorkspaceModel) -> Bool {
        // The sidebar document: at the top level of Pinned, or pinned inside its group (pinning-DESIGN.md).
        if let store = SidebarDocStore.current, store.isActive, let item = SidebarDocWiring.item(workspace: workspace.id, context.services.machines) {
            return store.records.isPinned(item: item)
        }
        guard pinsAreTiles else { return workspace.pinned }
        return refs.ref(forWorkspace: workspace.id).map(layout.document.isPinned) ?? false
    }

    /// Pins or unpins sidebar workspace `id`. Throws the refusal (no
    /// layout ref for the workspace, the owner refuses, or no pin
    /// capability on its daemon).
    func setWorkspacePinned(_ id: String, pinned: Bool, origin: ActionOrigin) throws {
        if let store = SidebarDocStore.current, store.isActive {
            if let item = SidebarDocWiring.item(workspace: id, context.services.machines) {
                pinned ? store.pin([item], title: PinStrings.pinWorkspace) : store.unpin([item], title: PinStrings.unpinWorkspace)
                // The document is the home daemon's: the workspace's own daemon (any session) gets the flag too.
                return WorkspacePinFlags.live(context.services.machines).mirror([id], pinned: pinned)
            }
            // A workspace the document does not place yet (a new one) is not pinned in it. The sidebar adopts
            // and pins it in one change; before its adopt ref is known (no resource id yet), the daemon's pin flag
            // is set instead, and the daemon adopts it into Pinned (`sidebar_doc_sync`). Unpin before that clears
            // the flag. Never a silent no-op.
            guard pinned else {
                guard context.services.machines.workspace(id: id)?.0.pinned == true else { return }
                return try setLegacyPinned(id, pinned: false, throughSidebar: false)
            }
            let drag = SidebarDocWiring.docMachines(context.services.machines).drag()
            if let sidebar = context.activeWindow?.sidebar, drag?.adoptRef(SidebarWorkspaceID(id)) != nil {
                return sidebar.handle(.setPinned([SidebarWorkspaceID(id)], true))
            }
            return try setLegacyPinned(id, pinned: true, throughSidebar: false)
        }
        if pinsAreTiles {
            guard let ref = refs.ref(forWorkspace: id) else { throw ActionFailure(message: PinStrings.workspaceCannotPin) }
            let document = layout.document
            let label = context.services.machines.workspace(id: id)?.0.displayName
            guard let op = pinned ? document.pinOp(ref, label: label) : document.unpinOp(ref) else { return }
            return try sendLayout(op, title: pinned ? PinStrings.pinWorkspace : PinStrings.unpinWorkspace, origin: origin)
        }
        try setLegacyPinned(id, pinned: pinned)
        guard origin == .user else { return }
        registerUndo(title: pinned ? PinStrings.pinWorkspace : PinStrings.unpinWorkspace) { commands in
            try? commands.setWorkspacePinned(id, pinned: !pinned, origin: .user)
        }
    }

    /// Pins or unpins every workspace in `ids` as one undo step (Pin on a selection).
    func setWorkspacesPinned(_ ids: [String], pinned: Bool, origin: ActionOrigin) throws {
        guard ids.count > 1 else {
            if let id = ids.first { try setWorkspacePinned(id, pinned: pinned, origin: origin) }
            return
        }
        let title = pinned ? PinStrings.pinWorkspace : PinStrings.unpinWorkspace
        if let store = SidebarDocStore.current, store.isActive {
            let items = ids.compactMap { SidebarDocWiring.item(workspace: $0, context.services.machines) }
            if items.count == ids.count {
                pinned ? store.pin(items, title: title) : store.unpin(items, title: title)
                return WorkspacePinFlags.live(context.services.machines).mirror(ids, pinned: pinned)
            }
        }
        if pinsAreTiles {
            let pins = try ids.map { id in
                guard let ref = refs.ref(forWorkspace: id) else { throw ActionFailure(message: PinStrings.workspaceCannotPin) }
                return (ref: ref, label: context.services.machines.workspace(id: id)?.0.displayName)
            }
            return try sendLayout(layout.document.pinOps(pins, pinned: pinned), title: title, origin: origin)
        }
        let changed = ids.filter { id in context.services.machines.workspace(id: id).map { $0.0.pinned != pinned } ?? false }
        for id in changed { try setLegacyPinned(id, pinned: pinned) }
        guard origin == .user, !changed.isEmpty else { return }
        registerUndo(title: title) { commands in
            for id in changed { try? commands.setLegacyPinned(id, pinned: !pinned) }
        }
    }

    /// Whether sidebar workspace `id` shows in the top rows (not as a tile).
    func isWorkspaceOnTopRows(_ id: String) -> Bool {
        guard pinsAreTiles, let ref = refs.ref(forWorkspace: id) else { return false }
        return layout.document.removeFromTopOp(ref) != nil
    }

    /// Adds sidebar workspace `id` to the top rows ("Add to Top", P1) or
    /// removes it from them; its tile, if any, stays. The workspace's name
    /// is stored with the row for when it is closed.
    func toggleWorkspaceOnTop(_ id: String, origin: ActionOrigin) throws {
        if let reason = SidebarDocWiring.layoutUnavailableReason(layout) { throw ActionFailure(message: reason) }
        guard let ref = refs.ref(forWorkspace: id) else { throw ActionFailure(message: PinStrings.workspaceCannotPin) }
        let document = layout.document
        if let remove = document.removeFromTopOp(ref) {
            return try sendLayout(remove, title: PinStrings.removeFromTop, origin: origin)
        }
        let label = context.services.machines.workspace(id: id)?.0.displayName
        guard let add = document.addToTopOp(ref, label: label) else { return }
        try sendLayout(add, title: PinStrings.addToTop, origin: origin)
    }

    /// Workspace rows dropped on top section `section` at `index`
    /// (drop-to-pin, P2): each one the section does not hold yet is added
    /// there in order, labeled with its name; one undo step each. A row
    /// with no layout ref is refused.
    func dropWorkspaces(_ ids: [String], on section: LayoutSectionID, at index: Int, origin: ActionOrigin) throws {
        if let reason = SidebarDocWiring.layoutUnavailableReason(layout) { throw ActionFailure(message: reason) }
        var at = index
        for id in ids {
            guard let ref = refs.ref(forWorkspace: id) else { throw ActionFailure(message: PinStrings.workspaceCannotPin) }
            guard layout.document.section(section)?.items.contains(where: { $0.ref == ref }) == false else { continue }
            let item = LayoutItem(id: .mint(), ref: ref, label: context.services.machines.workspace(id: id)?.0.displayName)
            let title = section == SidebarLayoutDocument.pinnedSectionID ? PinStrings.pinWorkspace : PinStrings.addToTop
            try sendLayout(.itemAdd(item, section: section, index: at), title: title, origin: origin)
            at += 1
        }
    }

    /// The sidebar's drop-to-pin (`SidebarIntent.dropOnLayoutSection`); a refusal is reported.
    func userDrop(_ ids: [String], on section: LayoutSectionID, at index: Int) {
        do { try dropWorkspaces(ids, on: section, at: index, origin: .user) } catch { context.services.registry.refuse(RefusalStrings.describe(error)) }
    }

    /// A band edit from the sidebar (`SidebarIntent.layout`): a reorder, or
    /// an item dragged out (a tile dropped on the list unpins it), which is
    /// an undo step (P4). A refusal is reported.
    func userBandEdit(_ op: SidebarLayoutOp) {
        do { try sendLayout(op, title: removalTitle(op) ?? "", origin: .user) } catch { context.services.registry.refuse(RefusalStrings.describe(error)) }
    }

    /// The undo title of an item removal from the top region: Unpin
    /// Workspace for a tile, Remove from Top for a top row; nil otherwise.
    func removalTitle(_ op: SidebarLayoutOp) -> String? {
        guard case let .itemRemove(id) = op, let (s, _) = layout.document.locate(id) else { return nil }
        return layout.document.sections[s].id == SidebarLayoutDocument.pinnedSectionID ? PinStrings.unpinWorkspace : PinStrings.removeFromTop
    }

    /// Several layout ops as one undo step (Add Group to Section). They are
    /// checked together first, so a reject (the item cap) leaves nothing half
    /// done; undo sends their inverses in reverse order and skips items that
    /// are already gone.
    func sendLayout(_ ops: [SidebarLayoutOp], title: String, origin: ActionOrigin) throws {
        // With the sidebar document, band edits are document ops (one change, one undo step).
        if try SidebarDocWiring.sendLayout(ops, over: layout.document, title: title, undoable: origin == .user) { return }
        let ops = ops.filter { op in
            guard case let .itemRemove(id) = op else { return true }
            return layout.document.locate(id) != nil
        }
        guard ops.count > 1 else {
            guard let op = ops.first else { return }
            return try sendLayout(op, title: title, origin: origin)
        }
        var checked = layout.document
        for op in ops {
            switch SidebarLayoutReducer.reduce(checked, op) {
            case .success(let next): checked = next
            case .failure(let reject): throw ActionFailure(message: SidebarSectionStrings.rejected(reject.rawValue))
            }
        }
        var inverses: [SidebarLayoutOp] = []
        for op in ops {
            let inverse = layout.document.inverse(of: op)
            try layout.send(op)
            if let inverse { inverses.insert(inverse, at: 0) }
        }
        guard origin == .user, !inverses.isEmpty else { return }
        registerUndo(title: title) { commands in
            do { try commands.sendLayout(inverses, title: title, origin: .user) } catch {
                commands.context.services.registry.refuse(RefusalStrings.describe(error))
            }
        }
    }

    /// Sends one layout change and, for the user, registers its inverse.
    func sendLayout(_ op: SidebarLayoutOp, title: String, origin: ActionOrigin) throws {
        if try SidebarDocWiring.sendLayout([op], over: layout.document, title: title, undoable: origin == .user) { return }
        let inverse = layout.document.inverse(of: op)
        try layout.send(op)
        guard origin == .user, let inverse else { return }
        registerUndo(title: title) { commands in
            do { try commands.sendLayout(inverse, title: title, origin: .user) } catch {
                commands.context.services.registry.refuse(RefusalStrings.describe(error))
            }
        }
    }

    /// The legacy flag through the window's sidebar (optimistic row move),
    /// else straight to the owning daemon.
    private func setLegacyPinned(_ id: String, pinned: Bool, throughSidebar: Bool = true) throws {
        guard let (workspace, daemon) = context.services.machines.workspace(id: id) else {
            throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn)
        }
        guard daemon.supports(DaemonCapability.workspacePin.rawValue) else {
            throw ActionFailure(message: daemon.missingCapabilityMessage(DaemonCapability.workspacePin.rawValue))
        }
        if throughSidebar, let sidebar = context.activeWindow?.sidebar {
            sidebar.handle(.setPinned([SidebarWorkspaceID(workspace.id)], pinned))
        } else if let key = workspace.key {
            daemon.send("set-workspace-metadata") { _ = try await $0.setWorkspaceMetadata(key, pinned: pinned) }
        }
    }
}
