public import Foundation
public import Observation

/// The lineage parent this Mac recorded for a session when an agent opened its workspace
/// (`agent.openSessionWorkspace` with a caller session: `cmux agent open`, `acpmux new --group`,
/// the app's MCP tools): child session -> the caller's session. It is the fallback for the
/// sidebar's session tree (`SidebarSessionTreeFeed`) when the session's daemon lists no lineage of
/// its own (`spawnedBy`/`startedBy`, later acpmux's `parent`), as a remote or older daemon does.
/// The daemon's lineage wins wherever it has one. Kept on this Mac, so a restored workspace nests
/// again after a relaunch.
@Observable @MainActor
public final class AgentSessionParents {

    /// Child session -> the session whose agent opened it (acpmux's `parent` field's meaning).
    public private(set) var parents: [String: String] = [:]
    /// The children in the order they were recorded, oldest first, so the cap drops the oldest.
    @ObservationIgnored private var order: [String] = []

    /// The most parents remembered; past it the oldest record goes.
    static let limit = 4096

    @ObservationIgnored private let defaults: UserDefaults?
    private static let key = "cmux.next.agentSession.lineageParents"

    private nonisolated struct Saved: Codable {
        var child: String
        var parent: String
    }

    /// `defaults` nil keeps the records in memory only (tests).
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
        let saved = defaults?.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Saved].self, from: $0) } ?? []
        for entry in saved.suffix(Self.limit) where Self.valid(entry.parent, of: entry.child) && parents[entry.child] == nil
            && !Self.descends(entry.parent, from: entry.child, in: parents) {
            order.append(entry.child)
            parents[entry.child] = entry.parent
        }
    }

    /// Records `parent` as `child`'s lineage parent. Nil, empty, the child itself or one of the child's
    /// own descendants (a cycle) records nothing; a later record for the same child replaces the earlier one.
    public func record(_ parent: String?, of child: String) {
        guard let parent, Self.valid(parent, of: child), parents[child] != parent,
              !Self.descends(parent, from: child, in: parents) else { return }
        var next = parents
        var order = order.filter { $0 != child }
        while order.count >= Self.limit, let oldest = order.first {
            order.removeFirst()
            next[oldest] = nil
        }
        order.append(child)
        next[child] = parent
        self.order = order
        parents = next
        save()
    }

    /// True when `session` is `root`'s child, a child's child, ... in `parents`.
    private static func descends(_ session: String, from root: String, in parents: [String: String]) -> Bool {
        var seen: Set<String> = []
        var next = parents[session]
        while let parent = next, seen.insert(parent).inserted {
            if parent == root { return true }
            next = parents[parent]
        }
        return false
    }

    private static func valid(_ parent: String, of child: String) -> Bool {
        !parent.isEmpty && !child.isEmpty && parent != child
    }

    private func save() {
        guard let defaults else { return }
        let entries = order.compactMap { child in parents[child].map { Saved(child: child, parent: $0) } }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }
}
