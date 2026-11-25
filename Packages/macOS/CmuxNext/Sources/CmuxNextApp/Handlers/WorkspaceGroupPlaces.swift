import CmuxNextActions
import CmuxNextDaemon
import CmuxNextSidebar

/// A workspace group's places outside the group (cx-a9h6, the group menu's
/// Section entry). Add Group to Section adds every member to a sidebar
/// section as workspace items, as Add to Sidebar does for one workspace, in
/// one undo step. The group stays a group; as with Add to Top,
/// a member held by a top-region section leaves the workspace list.
enum WorkspaceGroupPlaces {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("workspaceGroup.addToSection", run: { invocation in try addToSection(invocation, context) })
    }

    private static func addToSection(_ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let layout = context.services.sidebarLayout
        if let reason = context.services.sidebarDoc.layoutUnavailableReason(layout) { throw ActionFailure(message: reason) }
        let doc = layout.document
        // The palette and menus pass a section target; the CLI may name it.
        let section = if let target = invocation["section"]?.targetValue {
            try SidebarSectionResolve.section(target, in: doc)
        } else {
            try SidebarSectionResolve.section(invocation["section"]?.stringValue ?? "", in: doc)
        }
        guard case .items = section.content else { throw ActionFailure(message: RefusalStrings.sectionTakesNoWorkspaces) }
        let refs = WorkspaceLayoutRefs(machines: context.services.machines)
        var listed = Set(section.items.map(\.ref))
        // A workspace without a session or resource id has no layout ref (as
        // for Add to Sidebar); it is skipped.
        let named = try WorkspaceGroupHandlers.members(invocation, context).compactMap { refs.ref(forWorkspace: $0.id) }
        guard !named.isEmpty else { throw ActionFailure(message: RefusalStrings.groupCannotJoinSection) }
        let ops = named.filter { listed.insert($0).inserted }.map { ref -> SidebarLayoutOp in
            .itemAdd(LayoutItem(id: .mint(), ref: ref, label: refs.workspace(for: ref)?.0.displayName), section: section.id, index: Int.max)
        }
        guard !ops.isEmpty else { throw ActionFailure(message: RefusalStrings.groupAlreadyInSection) }
        let title = context.registry.descriptor(for: "workspaceGroup.addToSection")?.title ?? ""
        try PinCommands(context: context).sendLayout(ops, title: title, origin: invocation.origin)
    }
}
