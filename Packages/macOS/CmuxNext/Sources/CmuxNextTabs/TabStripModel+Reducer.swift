public import Foundation

extension TabStripModel {
    // MARK: - Local reducer

    /// Applies an intent to this model directly. The demo uses it as its
    /// whole backend; the App can use it for optimistic updates before the
    /// daemon confirms. Returns false for intents that need the App
    /// (rename, splits, columns, windows, drags between strips).
    @discardableResult
    public func apply(_ intent: TabStripIntent, makeTab: () -> TabItem) -> Bool {
        if let handled = applyGroupIntent(intent, makeTab: makeTab) {
            normalize()
            return handled
        }
        var ordered = orderedTabs
        switch intent {
        case .select(let id):
            guard let tab = tab(id) else { return false }
            selectedID = id
            // Selecting a member of a collapsed group expands it.
            if let group = tab.groupID { setCollapsed(group, false) }
        case .close(let id, _):
            let next = Self.selectionAfterClosing(id, in: ordered.map(\.id), selected: selectedID)
            ordered.removeAll { $0.id == id }
            tabs = ordered
            selectedID = next
        case .closeOthers(let keep):
            let closed = Set(closedByCloseOthers(keeping: keep))
            tabs = ordered.filter { !closed.contains($0.id) }
            selectedID = keep
        case .closeToRight(let id):
            guard ordered.contains(where: { $0.id == id }) else { return false }
            // Pinned tabs after `id` stay (Chrome).
            let closed = Set(closedByCloseToRight(of: id))
            tabs = ordered.filter { !closed.contains($0.id) }
            if let selectedID, closed.contains(selectedID) {
                self.selectedID = id
            }
        case .reorder(let id, _, let to):
            guard let from = ordered.firstIndex(where: { $0.id == id }) else { return false }
            let item = ordered.remove(at: from)
            ordered.insert(item, at: min(max(to, 0), ordered.count))
            tabs = ordered
        case .reorderTabs(let order):
            let byID = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            guard Set(order) == Set(byID.keys) else { return false }
            tabs = order.compactMap { byID[$0] }
        case .newTab(let after, _, _):
            var item = makeTab()
            if let after, let index = ordered.firstIndex(where: { $0.id == after }) {
                // A new tab opened from a grouped tab joins its group.
                item.groupID = ordered[index].groupID
                ordered.insert(item, at: index + 1)
            } else {
                ordered.append(item)
            }
            tabs = ordered
            select(item)
        case .toggleAudioMute(let id):
            // The demo's speaker: playing and muted swap (the App mutes the page instead).
            guard let index = tabs.firstIndex(where: { $0.id == id }), let audio = tabs[index].audio else { return false }
            tabs[index].audio = audio == .muted ? .playing : .muted
            return true
        case .pin(let id), .unpin(let id):
            guard tab(id) != nil else { return false }
            // Rebase on display order first so the tab lands at the end of
            // the pinned group (pin) or the start of the unpinned group (unpin).
            tabs = ordered
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
            if case .pin = intent {
                tabs[index].isPinned = true
                tabs[index].groupID = nil
            } else {
                tabs[index].isPinned = false
            }
        default:
            return false
        }
        normalize()
        return true
    }

    /// Selects `tab`, expanding its group if collapsed.
    func select(_ tab: TabItem) {
        selectedID = tab.id
        if let group = tab.groupID { setCollapsed(group, false) }
    }

    func setCollapsed(_ group: TabGroupID, _ collapsed: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == group }), groups[index].isCollapsed != collapsed else { return }
        groups[index].isCollapsed = collapsed
    }

    /// Keeps `tabs` in display order and drops groups with no members.
    func normalize() {
        let ordered = orderedTabs
        if ordered != tabs { tabs = ordered }
        let used = Set(ordered.compactMap(\.groupID))
        if groups.contains(where: { !used.contains($0.id) }) {
            groups.removeAll { !used.contains($0.id) }
        }
    }
}
