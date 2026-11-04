import AppKit
import CmuxNextDesign

// Reveal Workspace in Sidebar, the list's part (Lawrence msg 20167): the folds the list owns open, its row scrolls
// into view and flashes. The model's folds (groups, sections) open first (`SidebarView+RevealInSidebar`).
extension SidebarListViewComponents {
    /// Whether workspace `id`'s row is drawn and at least partly in view now.
    func isRowOnScreen(_ id: WorkspaceID) -> Bool {
        guard let clip = enclosingScrollView?.contentView else { return false }
        return displayed.isOnScreen(.workspace(id), at: clip.bounds.minY, height: clip.bounds.height)
    }

    /// Shows workspace `id`'s row: opens the list's own folds that hide it (the Archive, an "Archived (N)" or
    /// "Done (N)" row, then a "Show N more" row, each only while the row is still not drawn), scrolls it into view
    /// (to the middle when `centre`, else the least scroll) and flashes it. False when the list draws no row for it.
    func revealRow(_ id: WorkspaceID, centre: Bool) -> Bool {
        let key = SidebarRowKey.workspace(id)
        if displayed.row(for: key) == nil, let workspace = model.workspace(id) {
            let lists = model.revealLists(of: id)
            var folds: Set<SidebarDoneFoldID> = []
            if workspace.isArchived { folds.insert(.archive) }
            for list in lists {
                if workspace.isArchived { folds.insert(list.of(.archived)) }
                if workspace.taskStatus == .done { folds.insert(list.of(.done)) }
            }
            if !folds.isSubset(of: openDoneFolds) {
                openDoneFolds.formUnion(folds)
                reload(animated: true)
            }
            if displayed.row(for: key) == nil, !Set(lists).isSubset(of: openShowMore) {
                openShowMore.formUnion(lists)
                reload(animated: true)
            }
        }
        guard let row = displayed.row(for: key) else { return false }
        if let clip = enclosingScrollView?.contentView, clip.bounds.height > 0,
           let target = displayed.revealInSidebarOffset(key, from: clip.bounds.minY, height: clip.bounds.height, centre: centre),
           abs(target - clip.bounds.minY) > 0.25 {
            scrollClip(to: target, animated: true)
        }
        flashRevealed(row)
        return true
    }

    /// Flashes `row` (``SidebarRevealFlash``): blinks while cmux animates loops, else shows at once and goes at once.
    func flashRevealed(_ row: SidebarRow) {
        revealFlash?.remove()
        revealFlash = SidebarRevealFlash(key: row.key, frame: frame(for: row), in: self, animated: Motion.sidebar.animatesLoops)
    }
}
