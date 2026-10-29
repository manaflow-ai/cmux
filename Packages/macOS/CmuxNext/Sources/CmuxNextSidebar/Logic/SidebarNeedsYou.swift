public import CmuxNextDesign

/// One session blocked on you, in the session tree's needs-you tray.
public nonisolated struct SidebarNeedsYouItem: Hashable, Sendable, Identifiable {
    public nonisolated enum Reason: Hashable, Sendable {
        /// A question or a permission waits for you.
        case waiting
        /// Its last turn failed, or its agent is gone.
        case failed
    }

    public let id: WorkspaceID
    public let title: String
    /// The titles of the sessions that started it, top first ("Release week", "Settings pass").
    public let path: [String]
    public let reason: Reason
    /// What a hook said it waits for (a permission, a question, a sign-in), when it said.
    public let kind: StatusBlockedKind?

    public init(id: WorkspaceID, title: String, path: [String], reason: Reason, kind: StatusBlockedKind? = nil) {
        (self.id, self.title, self.path, self.reason, self.kind) = (id, title, path, reason, kind)
    }
}

/// The session tree's needs-you tray (`sidebar.sessionTree`, Leo 2026-10-18): only what is blocked
/// on you (a question or a permission waiting, a failure), in the order the tree draws its rows, with
/// the path to each, and a count of finished sessions you have not read. Running, idle and merely
/// unread sessions never enter the list; a folded parent never hides an item. Empty without the tree.
public nonisolated struct SidebarNeedsYou: Hashable, Sendable {
    public var items: [SidebarNeedsYouItem] = []
    /// Finished sessions with output you have not read: a count, never an item.
    public var unread = 0
    /// The first of them in drawn order, where the count's click goes.
    public var firstUnread: WorkspaceID?

    public init() {}

    public var isEmpty: Bool { items.isEmpty && unread == 0 }

    public static func make(_ sections: [SidebarSection], tree: SidebarSessionTreeState?) -> SidebarNeedsYou {
        var result = SidebarNeedsYou()
        guard let tree else { return result }
        var titles: [WorkspaceID: String] = [:]
        for ws in sections.flatMap(\.workspaces) where titles[ws.id] == nil { titles[ws.id] = ws.title }
        var seen: Set<WorkspaceID> = []
        func visit(_ ws: SidebarWorkspace) {
            guard ws.rowState != .placeholder, seen.insert(ws.id).inserted else { return }
            switch SidebarAgentState.of(ws, lane: tree.states[ws.id]) {
            case .blocked:
                result.items.append(item(ws, .waiting, tree: tree, titles: titles))
            case .failed:
                result.items.append(item(ws, .failed, tree: tree, titles: titles))
            case .finishedUnread:
                result.unread += 1
                if result.firstUnread == nil { result.firstUnread = ws.id }
            case .running, .idle:
                break
            }
        }
        // Each list as the tree draws it with every fold open: loose rows, and each group's members in its place.
        for section in sections {
            let nodes = section.nodes
            let ids = SidebarLayout.workspaceIDs(nodes)
            for (index, _) in SidebarLayout.treeOrder(ids, parents: tree.parents) {
                switch nodes[index] {
                case let .workspace(ws):
                    visit(ws)
                case let .group(group):
                    let members = group.members // computed: read once
                    for (member, _) in SidebarLayout.treeOrder(SidebarLayout.workspaceIDs(members), parents: tree.parents) {
                        if case let .workspace(ws) = members[member] { visit(ws) }
                    }
                case .item:
                    break
                }
            }
        }
        return result
    }

    private static func item(_ ws: SidebarWorkspace, _ reason: SidebarNeedsYouItem.Reason, tree: SidebarSessionTreeState,
                             titles: [WorkspaceID: String]) -> SidebarNeedsYouItem {
        var path: [String] = []
        var seen: Set<WorkspaceID> = [ws.id]
        var current = ws.id
        while let parent = tree.parents[current], let title = titles[parent], seen.insert(parent).inserted {
            path.insert(title, at: 0)
            current = parent
        }
        return SidebarNeedsYouItem(id: ws.id, title: ws.title, path: path, reason: reason, kind: ws.activity.blockedKind)
    }
}
