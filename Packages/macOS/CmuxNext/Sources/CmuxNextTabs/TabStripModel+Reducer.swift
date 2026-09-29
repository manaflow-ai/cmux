public import Foundation

extension TabStripModel {
    // MARK: - Local reducer

    /// Applies an intent to this model directly. The demo uses it as its
    /// whole backend; the App can use it for optimistic updates before the
    /// daemon confirms. Returns false for intents that need the App
    /// (rename, splits, columns, drags between strips).
    @discardableResult
    public func apply(_ intent: TabStripIntent, makeTab: () -> TabItem) -> Bool {
        var ordered = orderedTabs
        switch intent {
        case .select(let id):
            guard tab(id) != nil else { return false }
            selectedID = id
            return true
        case .close(let id, _):
            let next = Self.selectionAfterClosing(id, in: ordered.map(\.id), selected: selectedID)
            ordered.removeAll { $0.id == id }
            tabs = ordered
            selectedID = next
            return true
        case .closeOthers(let keep):
            tabs = ordered.filter { $0.id == keep || $0.isPinned }
            selectedID = keep
            return true
        case .closeToRight(let id):
            guard let index = ordered.firstIndex(where: { $0.id == id }) else { return false }
            let kept = Array(ordered[...index])
            tabs = kept
            if let selectedID, !kept.contains(where: { $0.id == selectedID }) {
                self.selectedID = id
            }
            return true
        case .reorder(let id, _, let to):
            guard let from = ordered.firstIndex(where: { $0.id == id }) else { return false }
            let item = ordered.remove(at: from)
            ordered.insert(item, at: min(max(to, 0), ordered.count))
            tabs = Self.pinnedFirst(ordered)
            return true
        case .newTab(let after):
            let item = makeTab()
            if let after, let index = ordered.firstIndex(where: { $0.id == after }) {
                ordered.insert(item, at: index + 1)
            } else {
                ordered.append(item)
            }
            tabs = Self.pinnedFirst(ordered)
            selectedID = item.id
            return true
        case .duplicate(let id):
            guard let index = ordered.firstIndex(where: { $0.id == id }) else { return false }
            var copy = makeTab()
            let source = ordered[index]
            copy.title = source.title
            copy.subtitle = source.subtitle
            copy.icon = source.icon
            copy.isPinned = source.isPinned
            ordered.insert(copy, at: index + 1)
            tabs = Self.pinnedFirst(ordered)
            selectedID = copy.id
            return true
        case .pin(let id), .unpin(let id):
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
            // Rebase on display order first so the tab lands at the end of
            // the pinned group (pin) or the start of the unpinned group (unpin).
            tabs = ordered
            let reindex = tabs.firstIndex(where: { $0.id == id }) ?? index
            if case .pin = intent { tabs[reindex].isPinned = true } else { tabs[reindex].isPinned = false }
            tabs = orderedTabs
            return true
        case .rename, .moveToNewSplit, .moveToNewColumn, .dragBegan:
            return false
        }
    }
}
