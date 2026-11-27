import Foundation

// Settled chats (`sidebar.settleFinished`): which listed rows fold behind their list's "Settled (N)" row, and what
// Archive Settled Chats archives. The rule is Rust's (`SidebarSettlePlanner`); the model asks once per change of its
// rows and keeps the answer for every layout and Cmd-number order of that change.
extension SidebarModel {
    /// The listed rows' facts in sidebar order, each workspace once; a row listed in Pinned is pinned.
    func settleFacts() -> [(id: WorkspaceID, facts: SidebarSettlePlanner.Facts)] {
        let pinnedSections: Set<SectionID> = [.pinned, .custom(SidebarDocStore.pinnedSection)]
        let pinned = Set(sections.filter { pinnedSections.contains($0.id) }.flatMap(\.workspaces).map(\.id))
        var seen: Set<WorkspaceID> = []
        var rows: [(id: WorkspaceID, facts: SidebarSettlePlanner.Facts)] = []
        for ws in allWorkspaces where seen.insert(ws.id).inserted {
            rows.append((ws.id, SidebarSettlePlanner.Facts(ws, pinned: pinned.contains(ws.id))))
        }
        return rows
    }

    /// The settled chats among the listed rows: empty with `sidebar.settleFinished` off. Cached by `contentRevision`.
    public func settledChats() -> Set<WorkspaceID> {
        guard settlesFinished else { return [] }
        if let cache = settleCache, cache.revision == contentRevision { return cache.settled }
        let settled = SidebarSettlePlanner().settled(settleFacts())
        settleCache = (contentRevision, settled)
        return settled
    }

    /// Archive Settled Chats over the listed rows: the settled chats to archive, and the unread, failed, lost and busy
    /// ones it leaves where they are.
    public func settleArchivePlan() -> SidebarSettlePlanner.ArchivePlan {
        SidebarSettlePlanner().archivePlan(settleFacts())
    }

    /// Whether a row patch from `old` to `new` settles or unsettles the chat (so the list moves it in or out of its
    /// "Settled (N)" row). The rule runs only when a fact it reads changed.
    static func settleMoves(from old: SidebarWorkspace, to new: SidebarWorkspace) -> Bool {
        // A patch keeps the row's list: a row in Pinned stays pinned, so the pin is no fact of the change.
        let before = SidebarSettlePlanner.Facts(old, pinned: false), after = SidebarSettlePlanner.Facts(new, pinned: false)
        guard before != after else { return false }
        let planner = SidebarSettlePlanner()
        return planner.settles(before) != planner.settles(after)
    }
}
