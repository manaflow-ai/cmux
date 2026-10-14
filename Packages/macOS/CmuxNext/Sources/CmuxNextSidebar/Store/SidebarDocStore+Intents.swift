import Foundation

extension SidebarDocStore {
    /// Sends a move intent as one document move (sidebar-v2 S4): a list
    /// reorder or group move (`DropPosition`, counted without the moved
    /// items, becomes an anchor next to a sibling the person saw), a band
    /// drop or reorder, Pin and Unpin (the old "pin group" is plain Pin: the
    /// group moves into Pinned). A group's collapse is client view state.
    /// False: not a move (the older path handles it).
    public func handle(_ intent: SidebarIntent, model: SidebarModel, drag: SidebarDocDrag, pinTitle: String, unpinTitle: String) -> Bool {
        let title = Self.moveTitle
        func items(_ ids: [WorkspaceID]) -> [String] {
            let found = ids.compactMap { drag.item(.workspace($0)) }
            return found.count == ids.count ? found : []
        }
        func layoutMove(_ moving: [String], _ section: LayoutSectionID, _ index: Int) {
            move(moving, to: SidebarDocDrag.target(section, index: index, moving: moving, layout: model.layout), title: title)
        }
        func setPinned(_ moving: [String], _ pinned: Bool) {
            if pinned { pin(moving, title: pinTitle) } else { unpin(moving, title: unpinTitle) }
        }
        switch intent {
        case .reorder(let ids, let position):
            guard let target = drag.target(position, moving: items(ids), model: model) else { return false }
            move(items(ids), to: target, title: title)
        case .reorderGroup(let group, let index):
            guard let section = model.sections.first(where: { $0.nodes.contains { $0.id == .group(group) } }),
                  let target = drag.target(DropPosition(section: section.id, index: index), moving: [group.rawValue], model: model) else { return false }
            move([group.rawValue], to: target, title: title)
        case .move(let ids, let group):
            guard let section = records.items[group.rawValue]?.section else { return false }
            move(items(ids), to: SidebarDocTarget(section: section, parent: group.rawValue), title: title)
        case .setPinned(let ids, let pinned):
            setPinned(items(ids), pinned)
        case .setGroupPinned(let group, let pinned):
            setPinned([group.rawValue], pinned)
        case .dropOnLayoutSection(let ids, let section, let index):
            layoutMove(items(ids), section, index)
        case .layout(.itemMove(let id, let section, let index)):
            layoutMove([id.rawValue], section, index)
        case .toggleCollapse(.group):
            model.apply(intent)
        default:
            return false
        }
        return true
    }
}
