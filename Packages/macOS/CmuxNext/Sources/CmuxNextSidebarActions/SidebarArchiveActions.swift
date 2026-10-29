public import CmuxNextActions
public import CmuxNextSidebar

/// What the archive actions read from the App: the targeted workspace and group, the rows a person's
/// run acts on, and the sidebar document item that places a workspace.
@MainActor
public protocol SidebarArchiveHost: AnyObject {
    /// The invocation's workspace id; throws when it targets none.
    func archiveWorkspace(_ invocation: ActionInvocation) throws -> String
    /// The workspace ids the run acts on: the selection for a person's menu run, else the target.
    func archiveRows(_ invocation: ActionInvocation) throws -> [String]
    /// The personal or document id of the invocation's group; throws when there is none.
    func archiveGroupID(_ invocation: ActionInvocation) throws -> String
    /// The document item that places workspace `id`; nil while it is not placed yet.
    func archiveItem(workspace id: String) -> String?
    /// What the person reads for an error the host threw.
    func archiveRefusal(_ error: any Error) -> String
}

/// Archive and Unarchive (plans/cmux-next/archiving-DESIGN.md): a workspace, a group or a link, tab
/// or app row stays in its group (or its section), moves last and draws dimmed; Unarchive puts it back
/// where it was. The mark is the item's row in the home daemon's sidebar document (`extra.archived`),
/// so it lasts across restarts; each toggle is one undo step. Every surface (the row menus, the
/// palette, the CLI, MCP) runs these actions, and the menus read Archive or Unarchive for the target.
/// The change shows at once (the mirror applies it); the store sends it and reports a refusal.
@MainActor
public final class SidebarArchiveActions {
    /// Held for the registry's life: the bound actions are its only owner.
    private let host: any SidebarArchiveHost
    private let store: () -> SidebarDocStore?

    public init(host: any SidebarArchiveHost, store: @escaping () -> SidebarDocStore? = { SidebarDocStore.current }) {
        self.host = host
        self.store = store
    }

    public func bind(into registry: ActionRegistry) {
        let unavailable: @MainActor () -> String? = { [self] in self.activeStore() == nil ? ArchiveStrings.needsDocument : nil }
        registry.bindEffect("workspace.toggleArchive", unavailable: unavailable, effect: { [self] invocation in
            // Every selected row takes the right-clicked row's new state, as Pin does.
            self.toggle(invocation, ArchiveStrings.archiveWorkspace, ArchiveStrings.unarchiveWorkspace) { [self] host in
                (try self.placed(host.archiveWorkspace(invocation)), try host.archiveRows(invocation).map { try self.placed($0) })
            }
        })
        registry.bindEffect("workspaceGroup.toggleArchive", unavailable: unavailable, effect: { [self] invocation in
            self.toggle(invocation, ArchiveStrings.archiveGroup, ArchiveStrings.unarchiveGroup) { [self] host in
                let item = try self.groupItem(host.archiveGroupID(invocation))
                return (item, [item])
            }
        })
        registry.bindEffect("sidebar.item.toggleArchive", unavailable: unavailable, effect: { [self] invocation in
            self.toggle(invocation, ArchiveStrings.archiveItem, ArchiveStrings.unarchiveItem) { [self] _ in
                guard let target = invocation.target, target.kind == .sidebarItem, self.activeStore()?.records.items[target.id] != nil else {
                    throw ArchiveRefusal(message: ArchiveStrings.noSuchItem)
                }
                return (target.id, [target.id])
            }
        })
        ActionTargetTitles.set("workspace.toggleArchive", in: registry) { [self] invocation in
            let item = (try? self.host.archiveWorkspace(invocation)).flatMap { self.host.archiveItem(workspace: $0) }
            return self.title(item, ArchiveStrings.archiveWorkspace, ArchiveStrings.unarchiveWorkspace)
        }
        ActionTargetTitles.set("workspaceGroup.toggleArchive", in: registry) { [self] invocation in
            let id = try? self.host.archiveGroupID(invocation)
            return self.title(id.map { self.groupItem($0) }, ArchiveStrings.archiveGroup, ArchiveStrings.unarchiveGroup)
        }
        ActionTargetTitles.set("sidebar.item.toggleArchive", in: registry) { [self] invocation in
            guard let target = invocation.target, target.kind == .sidebarItem else { return nil }
            return self.title(target.id, ArchiveStrings.archiveItem, ArchiveStrings.unarchiveItem)
        }
    }

    /// Archives `items` when the clicked one is not archived, else unarchives them: one change, one undo step.
    private func toggle(_ invocation: ActionInvocation, _ archiveTitle: String, _ unarchiveTitle: String,
                        _ items: (any SidebarArchiveHost) throws -> (clicked: String, all: [String])) -> ActionEffect {
        guard let store = activeStore() else { return .refused(ArchiveStrings.needsDocument) }
        do {
            let (clicked, all) = try items(host)
            let archived = !store.records.isArchived(item: clicked)
            try store.setArchived(all, archived: archived, title: archived ? archiveTitle : unarchiveTitle)
            return .done
        } catch let refusal as ArchiveRefusal {
            return .refused(refusal.message)
        } catch let refusal as SidebarDocSendRefusal {
            return .refused(refusal.message)
        } catch {
            return .refused(host.archiveRefusal(error))
        }
    }

    /// The menu title for document item `item`: Unarchive while it is archived; nil without the document.
    private func title(_ item: String?, _ archive: String, _ unarchive: String) -> String? {
        guard let store = activeStore(), let item, store.records.items[item] != nil else { return nil }
        return store.records.isArchived(item: item) ? unarchive : archive
    }

    /// The document item that places workspace `id`; a workspace not placed yet (an adopt in flight) cannot be archived.
    private func placed(_ id: String) throws -> String {
        guard let item = host.archiveItem(workspace: id) else { throw ArchiveRefusal(message: ArchiveStrings.notPlacedYet) }
        return item
    }

    /// The document item of group `id` (`itm_g_<id>` for a personal group, else the id itself).
    private func groupItem(_ id: String) -> String { activeStore()?.records.groupItem(personal: id) ?? id }

    private func activeStore() -> SidebarDocStore? { store().flatMap { $0.isActive ? $0 : nil } }
}

/// A refusal of the archive actions, with the message the person reads.
public struct ArchiveRefusal: Error {
    public var message: String
    public init(message: String) { self.message = message }
}
