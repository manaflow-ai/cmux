public import Foundation
import Observation

/// The chats a chat on another machine started there (its sub-sessions and `acpmux new` chats), as
/// that machine's daemon listed them for the chat's attachment (`agent-session-children-v1`,
/// ``RemoteAcpmuxWire``): each child's parent, so the sidebar's session tree nests them
/// (`SidebarSessionTreeFeed`) and the chat's Subagents rows open them (``AgentPaneSideChat``).
/// Only what a daemon answered is noted, never what a page sent. The links are what that
/// machine's acpmux reports, not proof of who started what: `spawnedBy` there is a tag any process
/// of its user can set.
@MainActor @Observable
public final class RemoteAgentSessionLinks {
    public static let shared = RemoteAgentSessionLinks()

    /// Child session -> the session that started it.
    public private(set) var parents: [String: String] = [:]

    /// The most children remembered (the list starts again past it).
    static let limit = 4096

    public init() {}

    /// Notes the parent of each summary (`sessionId` with `startedBy`, else `spawnedBy`).
    public func note(_ summaries: [[String: Any]]) {
        var parents = parents
        for summary in summaries {
            guard let child = summary["sessionId"] as? String, !child.isEmpty,
                  let parent = (summary["startedBy"] as? String) ?? (summary["spawnedBy"] as? String),
                  !parent.isEmpty, parent != child else { continue }
            if parents.count >= Self.limit, parents[child] == nil { parents.removeAll() }
            parents[child] = parent
        }
        if parents != self.parents { self.parents = parents }
    }

    /// True when `session` descends from `root` (a child, or a child's child, ...).
    public func descends(_ session: String, from root: String) -> Bool {
        var seen: Set<String> = []
        var next = parents[session]
        while let parent = next, seen.insert(parent).inserted {
            if parent == root { return true }
            next = parents[parent]
        }
        return false
    }
}
