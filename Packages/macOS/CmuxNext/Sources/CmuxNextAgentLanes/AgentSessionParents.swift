public import CmuxNextDaemon
public import Foundation
public import Observation

/// The lineage parent this Mac recorded for a session when an agent opened its workspace
/// (`agent.openSessionWorkspace` with a caller session). The identity includes the acpmux host:
/// session ids are scoped to a daemon, so a bare id cannot safely identify a chat across hosts.
/// The daemon's lineage wins wherever it has one. Kept on this Mac, so a restored workspace nests
/// again after a relaunch.
@Observable @MainActor
public final class AgentSessionParents {
    /// Canonical identity used for persistence and lookup; hostName and harness are intentionally omitted.
    public typealias Identity = AgentSessionRef

    /// Child session -> the session whose agent opened it (acpmux's `parent` field's meaning).
    public private(set) var parents: [Identity: Identity] = [:]
    /// The children in the order they were recorded, oldest first, so the cap drops the oldest.
    @ObservationIgnored private var order: [Identity] = []

    /// The most parents remembered; past it the oldest record goes.
    static let limit = 4096

    @ObservationIgnored private let defaults: UserDefaults?
    private static let key = "cmux.next.agentSession.lineageParents"

    private nonisolated struct Saved: Codable {
        var childHost: String
        var childSession: String
        var parentHost: String
        var parentSession: String
    }

    /// `defaults` nil keeps the records in memory only (tests).
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
        let saved = defaults?.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Saved].self, from: $0) } ?? []
        for entry in saved.suffix(Self.limit) {
            let child = Self.identity(host: entry.childHost, session: entry.childSession)
            let parent = Self.identity(host: entry.parentHost, session: entry.parentSession)
            guard Self.valid(parent), Self.valid(child), Self.valid(parent, of: child), parents[child] == nil,
                  !Self.descends(parent, from: child, in: parents) else { continue }
            order.append(child)
            parents[child] = parent
        }
    }

    /// Records `parent` as `child`'s lineage parent. Nil, empty, the child itself or one of the child's
    /// own descendants (a cycle) records nothing; a later record for the same child replaces the earlier one.
    public func record(_ parent: Identity?, of child: Identity) {
        guard let parent, Self.valid(parent), Self.valid(child), Self.valid(parent, of: child), parents[child] != parent,
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

    /// Canonicalizes an ``AgentSessionRef`` to host and session only for safe cross-host lookup.
    public static func identity(host: String, session: String) -> Identity {
        Identity(host: host, session: session)
    }

    /// True when `session` is `root`'s child, a child's child, ... in `parents`.
    private static func descends(_ session: Identity, from root: Identity, in parents: [Identity: Identity]) -> Bool {
        var seen: Set<Identity> = []
        var next = parents[session]
        while let parent = next, seen.insert(parent).inserted {
            if parent == root { return true }
            next = parents[parent]
        }
        return false
    }

    private static func valid(_ identity: Identity) -> Bool {
        !identity.host.isEmpty && !(identity.session ?? "").isEmpty
    }

    /// The workspace one of whose tabs is `session`'s chat, nil when none of `workspaces` has one (or no `session`).
    public static func workspace(of session: Identity?, in workspaces: [WorkspaceModel]) -> String? {
        guard let session else { return nil }
        return workspaces.first { workspace in
            workspace.screens.flatMap(\.panes).flatMap(\.tabs).contains { tab in
                tab.agentSession.map { $0.host == session.host && $0.session == session.session } == true
            }
        }?.id
    }

    private static func valid(_ parent: Identity, of child: Identity) -> Bool {
        parent != child
    }

    private func save() {
        guard let defaults else { return }
        let entries = order.compactMap { child -> Saved? in
            guard let parent = parents[child], let childSession = child.session, let parentSession = parent.session else { return nil }
            return Saved(childHost: child.host, childSession: childSession, parentHost: parent.host, parentSession: parentSession)
        }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }
}
