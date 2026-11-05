/// Mouse and accessibility activation share the fold's view-state change and layout update.
@MainActor struct SidebarFoldAction {
    let list: SidebarListView

    func toggle(_ key: SidebarRowKey) -> Bool {
        // A stale accessibility element must not toggle a fold that is no longer drawn.
        guard list.displayed.row(for: key) != nil else { return false }
        switch key {
        case let .doneFold(id):
            if list.openDoneFolds.remove(id) == nil { list.openDoneFolds.insert(id) }
        case let .showMore(id):
            if list.openShowMore.remove(id) == nil { list.openShowMore.insert(id) }
        default:
            return false
        }
        list.reload(animated: true)
        return true
    }
}
