import Foundation

// Automatic sessions (`sidebar.showAutomaticSessions`, off by default): which listed rows fold behind their list's
// "Automatic (N)" row. The rule is Rust's (`SidebarAutomaticPlanner`); the model asks once per change of its rows and
// keeps the answer for every layout and Cmd-number order of that change.
extension SidebarModel {
    /// The automatic sessions among the listed rows: empty with `sidebar.showAutomaticSessions` on. Cached by
    /// `contentRevision`.
    public func automaticSessions() -> Set<WorkspaceID> {
        guard !showsAutomaticSessions else { return [] }
        if let cache = automaticCache, cache.revision == contentRevision { return cache.automatic }
        let pinnedSections: Set<SectionID> = [.pinned, .custom(SidebarDocStore.pinnedSection)]
        let pinned = Set(sections.filter { pinnedSections.contains($0.id) }.flatMap(\.workspaces).map(\.id))
        var seen: Set<WorkspaceID> = []
        var rows: [(id: WorkspaceID, facts: SidebarAutomaticPlanner.Facts)] = []
        for ws in allWorkspaces where seen.insert(ws.id).inserted {
            rows.append((ws.id, SidebarAutomaticPlanner.Facts(ws, pinned: pinned.contains(ws.id))))
        }
        let automatic = SidebarAutomaticPlanner().automatic(rows, showAutomatic: false)
        automaticCache = (contentRevision, automatic)
        return automatic
    }

    /// Whether a row patch from `old` to `new` moves the row in or out of its list's "Automatic (N)" row: who made it,
    /// or whether an automatic row needs the person.
    static func automaticMoves(from old: SidebarWorkspace, to new: SidebarWorkspace) -> Bool {
        let before = SidebarAutomaticPlanner.Facts(old, pinned: false), after = SidebarAutomaticPlanner.Facts(new, pinned: false)
        guard before != after, SidebarAutomaticPlanner.mayFold(before) || SidebarAutomaticPlanner.mayFold(after) else { return false }
        return true
    }
}
