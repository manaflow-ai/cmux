import Foundation

extension TabStripModel {
    /// Group intents for the local reducer. Nil when `intent` is not a
    /// group intent; otherwise whether it was applied.
    func applyGroupIntent(_ intent: TabStripIntent, makeTab: () -> TabItem) -> Bool? {
        switch intent {
        case .toggleGroupCollapsed(let group):
            return toggleCollapsed(group, makeTab: makeTab)
        case .moveGroup(let group, let to):
            var ordered = orderedTabs
            let members = ordered.filter { $0.groupID == group }
            guard !members.isEmpty else { return false }
            ordered.removeAll { $0.groupID == group }
            let pinned = ordered.count(where: \.isPinned)
            ordered.insert(contentsOf: members, at: min(max(to, pinned), ordered.count))
            tabs = ordered
            return true
        case .addToGroup(let id, let group, let index):
            guard self.group(group) != nil, let tab = tab(id), !tab.isPinned else { return false }
            var ordered = orderedTabs
            ordered.removeAll { $0.id == id }
            var moved = tab
            moved.groupID = group
            let lastMember = ordered.lastIndex { $0.groupID == group }
            let target = index ?? lastMember.map { $0 + 1 } ?? ordered.count
            ordered.insert(moved, at: min(max(target, 0), ordered.count))
            tabs = ordered
            return true
        case .removeFromGroup(let id, let index):
            guard let tab = tab(id), let group = tab.groupID else { return false }
            var ordered = orderedTabs
            ordered.removeAll { $0.id == id }
            var moved = tab
            moved.groupID = nil
            let afterGroup = ordered.lastIndex { $0.groupID == group }.map { $0 + 1 }
            let target = index ?? afterGroup ?? ordered.count
            ordered.insert(moved, at: min(max(target, 0), ordered.count))
            tabs = ordered
            return true
        case .createGroup(let item, let ids):
            let members = Set(ids)
            guard group(item.id) == nil, tabs.contains(where: { members.contains($0.id) && !$0.isPinned }) else { return false }
            groups.append(item)
            for index in tabs.indices where members.contains(tabs[index].id) && !tabs[index].isPinned {
                tabs[index].groupID = item.id
            }
            return true
        case .group(let command):
            return applyGroupCommand(command, makeTab: makeTab)
        case .groupDragBegan:
            return false
        default:
            return nil
        }
    }

    private func toggleCollapsed(_ group: TabGroupID, makeTab: () -> TabItem) -> Bool {
        guard let item = self.group(group) else { return false }
        if item.isCollapsed {
            setCollapsed(group, false)
            return true
        }
        // Collapsing moves the selection out of the group first.
        let ordered = orderedTabs
        let collapsed = Set(groups.filter(\.isCollapsed).map(\.id))
        if tab(selectedID ?? TabID(""))?.groupID == group {
            if let next = TabGroupOrdering.selectionAfterCollapsing(group, in: ordered, collapsed: collapsed, selected: selectedID) {
                selectedID = next
            } else {
                // Every visible tab is in the group: open a new tab.
                let fresh = makeTab()
                tabs = ordered + [fresh]
                selectedID = fresh.id
            }
        }
        setCollapsed(group, true)
        return true
    }

    private func applyGroupCommand(_ command: TabGroupCommand, makeTab: () -> TabItem) -> Bool {
        let id = command.groupID
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        switch command {
        case .rename(_, let name):
            groups[index].name = name
        case .setColor(_, let color):
            groups[index].colorToken = color
        case .save:
            groups[index].isSaved = true
        case .unsave:
            groups[index].isSaved = false
        case .newTab:
            var ordered = orderedTabs
            var item = makeTab()
            item.groupID = id
            let target = ordered.lastIndex { $0.groupID == id }.map { $0 + 1 } ?? ordered.count
            ordered.insert(item, at: target)
            tabs = ordered
            select(item)
        case .ungroup:
            for tab in tabs.indices where tabs[tab].groupID == id { tabs[tab].groupID = nil }
        case .close:
            let ordered = orderedTabs
            let remaining = ordered.filter { $0.groupID != id }
            if let selectedID, !remaining.contains(where: { $0.id == selectedID }) {
                let index = ordered.firstIndex { $0.id == selectedID } ?? 0
                self.selectedID = ordered[index...].first { $0.groupID != id }?.id ?? remaining.last?.id
            }
            tabs = remaining
        case .moveToNewWindow:
            return false
        }
        return true
    }
}
