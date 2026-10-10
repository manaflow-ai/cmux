import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextSidebar

/// A workspace group's places outside the group (cx-a9h6, the group menu's
/// Section and Reveal in Finder). Show Group in Finder selects every member's
/// folder in one Finder window. Add Group to Section adds every member to a
/// sidebar section as workspace items, as Add to Sidebar does for one
/// workspace, in one undo step; the group itself stays where it is.
enum WorkspaceGroupPlaces {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("workspaceGroup.revealInFinder", run: { invocation in
            let members = try WorkspaceGroupHandlers.members(invocation, context)
            var seen = Set<String>()
            let folders = members.compactMap { WorkspaceMetadataHandlers.directory(of: $0, context) }.filter { seen.insert($0).inserted }
            guard !folders.isEmpty else { throw ActionFailure.invalidTarget(RefusalStrings.groupHasNoDirectory) }
            NSWorkspace.shared.activateFileViewerSelecting(folders.map { URL(fileURLWithPath: $0) })
        })
        registry.bind("workspaceGroup.addToSection", run: { invocation in try addToSection(invocation, context) })
    }

    private static func addToSection(_ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let layout = context.services.sidebarLayout
        if let reason = layout.unavailableReason { throw ActionFailure(message: reason) }
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
        let ops = try WorkspaceGroupHandlers.members(invocation, context).compactMap { workspace -> SidebarLayoutOp? in
            guard let ref = refs.ref(forWorkspace: workspace.id), listed.insert(ref).inserted else { return nil }
            let label = refs.workspace(for: ref)?.0.displayName
            return .itemAdd(LayoutItem(id: .mint(), ref: ref, label: label), section: section.id, index: Int.max)
        }
        guard !ops.isEmpty else { throw ActionFailure(message: RefusalStrings.groupAlreadyInSection) }
        let title = context.registry.descriptor(for: "workspaceGroup.addToSection")?.title ?? ""
        try PinCommands(context: context).sendLayout(ops, title: title, origin: invocation.origin)
    }
}
