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
            reveal(id)
        default:
            return false
        }
        list.reload(animated: true)
        return true
    }

    /// "Show N more" reveals the next rows (20 at a time, Rust's `sidebar_caps`); "Show less" folds back to the cap.
    /// The window shows it at once; a project's count goes to the document after.
    private func reveal(_ id: SidebarDoneFoldID) {
        let project = id.group.flatMap { list.model.group($0) }
        let o = list.model.rowOptions()
        guard let caps = SidebarLayout.caps(list: id, project: project, options: o),
              let row = list.displayed.row(for: .showMore(id)) else { return }
        let revealed = row.childCount == 0 ? 0 : caps.revealed + row.childCount
        list.model.revealedRows[id] = revealed
        // The document keeps it (no undo entry), so the project opens as it was left, here and in other windows.
        if let group = id.group, project != nil { list.model.docDrag?.document?.setGroupRevealed(group, revealed) }
    }
}
