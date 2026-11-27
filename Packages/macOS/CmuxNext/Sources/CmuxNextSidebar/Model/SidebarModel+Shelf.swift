import Foundation

// The working shelf (`sidebar.workingShelf`): which listed rows fold behind their list's "Working (N)" row. The rule
// is Rust's (`SidebarShelfPlanner`); the model asks once per change of its rows and keeps the answer for every layout
// and Cmd-number order of that change.
extension SidebarModel {
    /// The chats on the working shelf among the listed rows: empty with `sidebar.workingShelf` off. Cached by
    /// `contentRevision`.
    public func shelvedChats() -> Set<WorkspaceID> {
        guard shelvesWaiting else { return [] }
        if let cache = shelfCache, cache.revision == contentRevision { return cache.shelved }
        let pinnedSections: Set<SectionID> = [.pinned, .custom(SidebarDocStore.pinnedSection)]
        let pinned = Set(sections.filter { pinnedSections.contains($0.id) }.flatMap(\.workspaces).map(\.id))
        var seen: Set<WorkspaceID> = []
        var rows: [(id: WorkspaceID, facts: SidebarShelfPlanner.Facts)] = []
        for ws in allWorkspaces where seen.insert(ws.id).inserted {
            rows.append((ws.id, SidebarShelfPlanner.Facts(ws, pinned: pinned.contains(ws.id))))
        }
        let shelved = SidebarShelfPlanner().shelved(rows)
        shelfCache = (contentRevision, shelved)
        return shelved
    }

    /// Whether a row patch from `old` to `new` puts the chat on or takes it off the shelf (so the list moves it in or
    /// out of its "Working (N)" row). The rule runs only when a fact it reads changed.
    static func shelfMoves(from old: SidebarWorkspace, to new: SidebarWorkspace) -> Bool {
        let before = SidebarShelfPlanner.Facts(old, pinned: false), after = SidebarShelfPlanner.Facts(new, pinned: false)
        guard before != after else { return false }
        let planner = SidebarShelfPlanner()
        return planner.shelves(before) != planner.shelves(after)
    }
}
