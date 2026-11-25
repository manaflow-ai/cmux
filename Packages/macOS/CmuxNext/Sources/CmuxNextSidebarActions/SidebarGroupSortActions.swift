public import CmuxNextActions
public import CmuxNextSidebar

/// A group's Sort (Manual, Name, Recent; Leo 2026-11-03: "honestly i think we ought to be able to sort/filter
/// the group alphabetically or smth..."): `workspaceGroup.setSort` stores it on the group in the home daemon's
/// sidebar document (`extra.sort`), one undo step. Every surface runs it: the group editor's Sort row and the
/// group menu's Move > Sort Order (both this action's choices, the group's own sort checked), the palette, the
/// CLI and MCP.
@MainActor
public final class SidebarGroupSortActions {
    private let host: any SidebarArchiveHost
    private let store: @MainActor () -> SidebarDocStore?

    /// - Parameter host: names the invocation's group and gives the sidebar document (the archive actions' host).
    public init(host: any SidebarArchiveHost) {
        self.host = host
        store = { [weak host] in host?.archiveDocument }
    }

    public func bind(into registry: ActionRegistry) {
        let unavailable: @MainActor () -> String? = { [self] in self.activeStore() == nil ? ArchiveStrings.groupSortNeedsDocument : nil }
        registry.bindEffect("workspaceGroup.setSort", unavailable: unavailable, effect: { [self] invocation in
            guard let store = self.activeStore() else { return .refused(ArchiveStrings.groupSortNeedsDocument) }
            guard let sort = invocation["sort"]?.stringValue.flatMap(SidebarGroupSort.init(rawValue:)) else {
                return .refused(ArchiveStrings.groupSortBadValue)
            }
            do {
                try store.setGroupSort(self.group(invocation, in: store), sort)
                return .done
            } catch let refusal as SidebarDocSendRefusal {
                return .refused(refusal.message)
            } catch {
                return .refused(self.host.archiveRefusal(error))
            }
        })
        // The choices check the group's own sort.
        ActionTargetTitles.setChoiceState("workspaceGroup.setSort", in: registry) { [self] target in
            guard let store = self.activeStore(), let group = try? self.group(ActionInvocation(target: target), in: store) else { return nil }
            return store.groupSort(group).rawValue
        }
    }

    /// The invocation's group: a personal group by id or name, else a group target the document holds (a nested
    /// group made in the sidebar has no personal row; the editor names it by its document item).
    private func group(_ invocation: ActionInvocation, in store: SidebarDocStore) throws -> GroupID {
        do {
            return try GroupID(host.archiveGroupID(invocation))
        } catch {
            guard let target = invocation.target, target.kind == .workspaceGroup, store.records.items[target.id]?.body.isGroup == true else { throw error }
            return GroupID(target.id)
        }
    }

    private func activeStore() -> SidebarDocStore? { store().flatMap { $0.isActive ? $0 : nil } }
}
