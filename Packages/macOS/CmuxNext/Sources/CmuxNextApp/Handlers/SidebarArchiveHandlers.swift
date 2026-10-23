import CmuxNextActions
import CmuxNextSidebar

/// Archive and Unarchive (plans/cmux-next/archiving-DESIGN.md): a workspace, a group or a link, tab
/// or app row stays in its group (or its section), moves last and draws dimmed; Unarchive puts it back
/// where it was. The mark is the item's row in the home daemon's sidebar document (`extra.archived`),
/// so it lasts across restarts; each toggle is one undo step. Every surface (the row menus, the
/// palette, the CLI, MCP) runs these actions, and the menus read Archive or Unarchive for the target.
@MainActor
enum SidebarArchiveHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let unavailable: @MainActor () -> String? = { SidebarDocStore.current?.isActive == true ? nil : ArchiveStrings.needsDocument }
        registry.bind("workspace.toggleArchive", unavailable: unavailable, run: { invocation in
            // Every selected row takes the right-clicked row's new state, as Pin does.
            let store = try activeStore()
            let clicked = try workspaceItem(context.workspace(invocation).model.id, context)
            let archived = !store.records.isArchived(item: clicked)
            let items = try WindowMembershipHandlers.rowTargets(invocation, context).map { try workspaceItem($0.id, context) }
            try store.setArchived(items, archived: archived, title: archived ? ArchiveStrings.archiveWorkspace : ArchiveStrings.unarchiveWorkspace)
        })
        ActionTargetTitles.set("workspace.toggleArchive", in: registry) { invocation in
            guard let store = SidebarDocStore.current, store.isActive, let workspace = try? context.workspace(invocation).model,
                  let item = SidebarDocWiring.item(workspace: workspace.id, context.services.machines) else { return nil }
            return store.records.isArchived(item: item) ? ArchiveStrings.unarchiveWorkspace : ArchiveStrings.archiveWorkspace
        }
        registry.bind("workspaceGroup.toggleArchive", unavailable: unavailable, run: { invocation in
            let store = try activeStore(), item = groupItem(try context.group(invocation).id.rawValue, store)
            let archived = !store.records.isArchived(item: item)
            try store.setArchived([item], archived: archived, title: archived ? ArchiveStrings.archiveGroup : ArchiveStrings.unarchiveGroup)
        })
        ActionTargetTitles.set("workspaceGroup.toggleArchive", in: registry) { invocation in
            guard let store = SidebarDocStore.current, store.isActive, let group = try? context.group(invocation) else { return nil }
            let item = groupItem(group.id.rawValue, store)
            return store.records.isArchived(item: item) ? ArchiveStrings.unarchiveGroup : ArchiveStrings.archiveGroup
        }
        registry.bind("sidebar.item.toggleArchive", unavailable: unavailable, run: { invocation in
            let store = try activeStore()
            guard let target = invocation.target, target.kind == .sidebarItem, store.records.items[target.id] != nil else {
                throw ActionFailure.invalidTarget(SidebarSectionStrings.noSuchItem)
            }
            let archived = !store.records.isArchived(item: target.id)
            try store.setArchived([target.id], archived: archived, title: archived ? ArchiveStrings.archiveItem : ArchiveStrings.unarchiveItem)
        })
        ActionTargetTitles.set("sidebar.item.toggleArchive", in: registry) { invocation in
            guard let store = SidebarDocStore.current, store.isActive, let target = invocation.target, target.kind == .sidebarItem,
                  store.records.items[target.id] != nil else { return nil }
            return store.records.isArchived(item: target.id) ? ArchiveStrings.unarchiveItem : ArchiveStrings.archiveItem
        }
    }

    private static func activeStore() throws -> SidebarDocStore {
        guard let store = SidebarDocStore.current, store.isActive else { throw ActionFailure(message: ArchiveStrings.needsDocument) }
        return store
    }

    /// The document item of group `id` (`itm_g_<id>` for a personal group, else the id itself).
    private static func groupItem(_ id: String, _ store: SidebarDocStore) -> String { store.records.groupItem(personal: id) ?? id }

    /// The document item that places workspace `id`; a workspace the document does not place yet cannot be archived.
    private static func workspaceItem(_ id: String, _ context: AppActionContext) throws -> String {
        guard let item = SidebarDocWiring.item(workspace: id, context.services.machines) else {
            throw ActionFailure(message: ArchiveStrings.notPlacedYet)
        }
        return item
    }
}

/// Archive titles and refusals (Handlers.xcstrings): the menu rows read as the change they make,
/// and each is the undo step's name.
nonisolated enum ArchiveStrings {
    static var archiveWorkspace: String { text("archive.archiveWorkspace", "Archive Workspace") }
    static var unarchiveWorkspace: String { text("archive.unarchiveWorkspace", "Unarchive Workspace") }
    static var archiveGroup: String { text("archive.archiveGroup", "Archive Group") }
    static var unarchiveGroup: String { text("archive.unarchiveGroup", "Unarchive Group") }
    static var archiveItem: String { text("archive.archiveItem", "Archive Item") }
    static var unarchiveItem: String { text("archive.unarchiveItem", "Unarchive Item") }
    static var needsDocument: String { text("archive.refusal.needsDocument", "this sidebar cannot archive items yet") }
    static var notPlacedYet: String { text("archive.refusal.notPlacedYet", "the workspace is still being added to the sidebar") }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Handlers", bundle: .module)
    }
}
