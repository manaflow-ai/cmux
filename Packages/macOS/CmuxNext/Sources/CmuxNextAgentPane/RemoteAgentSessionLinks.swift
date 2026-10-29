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

    /// Child session -> the session that started it for legacy callers that have one daemon.
    public private(set) var parents: [String: String] = [:]
    /// Child session -> parent, scoped by the owning remote daemon host.
    public private(set) var parentsByHost: [String: [String: String]] = [:]

    /// The most children remembered (the list starts again past it).
    static let limit = 4096

    public init() {}

    /// Notes the parent of each summary (`sessionId` with `startedBy`, else `spawnedBy`).
    /// A host-qualified note keeps identical ids from separate remote daemons distinct.
    public func note(_ summaries: [[String: Any]], host: String? = nil) {
        var parents: [String: String]
        if let host { parents = parentsByHost[host] ?? [:] } else { parents = self.parents }
        for summary in summaries {
            guard let child = summary["sessionId"] as? String, !child.isEmpty,
                  let parent = (summary["startedBy"] as? String) ?? (summary["spawnedBy"] as? String),
                  !parent.isEmpty, parent != child else { continue }
            if parents.count >= Self.limit, parents[child] == nil { parents.removeAll() }
            parents[child] = parent
        }
        if let host {
            if parentsByHost[host] != parents { parentsByHost[host] = parents }
        } else if parents != self.parents {
            self.parents = parents
        }
    }

    /// The parent recorded by one daemon. A host-qualified query reads that host's map; it falls back
    /// to the unqualified legacy map only when that host has no map at all (a hostless route noted
    /// its links there), so identical session ids from a daemon that has its own map stay isolated.
    public func parent(of child: String, host: String? = nil) -> String? {
        links(host)[child]
    }

    /// The links one daemon's queries read: `host`'s own map, else (no map for `host`, or no host)
    /// the unqualified legacy map.
    public func links(_ host: String?) -> [String: String] {
        host.flatMap { parentsByHost[$0] } ?? parents
    }

    /// True when `session` descends from `root` (a child, or a child's child, ...).
    public func descends(_ session: String, from root: String, host: String? = nil) -> Bool {
        var seen: Set<String> = []
        let links = links(host)
        var next = links[session]
        while let parent = next, seen.insert(parent).inserted {
            if parent == root { return true }
            next = links[parent]
        }
        return false
    }
}
