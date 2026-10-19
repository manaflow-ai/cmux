public import CmuxNextDaemon
public import CmuxNextSidebar
public import Foundation

/// The home daemon's sidebar document (`sidebar-doc-v1`) for
/// `SidebarDocStore`: the wire calls of `SidebarDocClient`, as JSON bytes
/// the client mirror reads.
@MainActor
public final class DaemonSidebarDocRemote: SidebarDocRemote {
    private let connection: @MainActor () -> DaemonConnection?
    private let serves: @MainActor () -> Bool

    /// `connection`: the home daemon's connection; `serves`: whether it
    /// advertises `sidebar-doc-v1`.
    public init(connection: @escaping @MainActor () -> DaemonConnection?, serves: @escaping @MainActor () -> Bool) {
        self.connection = connection
        self.serves = serves
    }

    public var isAvailable: Bool { connection() != nil && serves() }

    private func client() throws -> SidebarDocClient {
        guard let connection = connection() else { throw DaemonError.notConnected }
        return SidebarDocClient(connection: connection)
    }

    public func get() async throws -> Data { try JSONEncoder().encode(try await client().get()) }

    public func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply {
        let to = try await SidebarDocWire.json(JSONValue.self, from: JSONEncoder().encode(target))
        return try await Self.answered { try Self.reply(try await client().move(items: items, to: to, idempotencyKey: key)) }
    }

    public func pin(_ items: [String], key: String) async throws -> SidebarDocReply {
        try await Self.answered { try Self.reply(try await client().pin(items: items, idempotencyKey: key)) }
    }

    public func unpin(_ items: [String], key: String) async throws -> SidebarDocReply {
        try await Self.answered { try Self.reply(try await client().unpin(items: items, idempotencyKey: key)) }
    }

    public func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply {
        let values = try await SidebarDocWire.json([JSONValue].self, from: JSONEncoder().encode(refs))
        return try Self.reply(try await client().adopt(refs: values, idempotencyKey: key))
    }

    public func apply(ops: Data, key: String) async throws -> SidebarDocReply {
        let values = try await SidebarDocWire.json([JSONValue].self, from: ops)
        return try await Self.answered { try Self.reply(try await client().apply(ops: values, idempotencyKey: key)) }
    }

    /// A mutation that got no answer (no reply in time, the connection closed) is `SidebarDocUnsettled`: the daemon
    /// may have applied it, so the store asks again under the same key instead of dropping its intent.
    private static func answered(_ body: @MainActor () async throws -> SidebarDocReply) async throws -> SidebarDocReply {
        do {
            return try await body()
        } catch let error as DaemonError {
            switch error {
            // No connection yet (between asks, a reconnect): an earlier ask may still have reached the daemon.
            case .timedOut, .connectionClosed, .daemonShutdown, .notConnected, .connectFailed: throw SidebarDocUnsettled()
            default: throw error
            }
        }
    }

    private static func reply(_ mutation: SidebarDocMutation) throws -> SidebarDocReply {
        SidebarDocReply(revision: mutation.revision, inverse: try JSONEncoder().encode(JSONValue.array(mutation.inverse)))
    }

    /// Forwards the home session's document batches and stream snapshots to `store`.
    public static func follow(_ session: SessionStateStore, into store: SidebarDocStore) {
        session.onSidebarBatch = { [weak store] batch in
            guard let data = try? JSONEncoder().encode(batch.json) else { return }
            store?.receive(batch: data)
        }
        session.onSidebarResync = { [weak store] in store?.refresh() }
    }
}

/// The document's machine nodes as the daemon-level sections the sidebar
/// mapping reads (`PersonalSidebar.sections` on the document). One group
/// model per document group, updated in place, so a group keeps its identity.
@MainActor
public final class SidebarDocSections {
    private var groups: [String: WorkspaceGroupModel] = [:]

    public init() {}

    /// The document ref of `workspace` on the session `session`.
    public static func ref(of workspace: WorkspaceModel, session: String?) -> SidebarDocWorkspaceRef? {
        guard let session, let resource = workspace.resourceID?.rawValue else { return nil }
        return SidebarDocWorkspaceRef(sessionID: session, workspaceID: resource)
    }

    /// `session`'s sections in document order over `workspaces` (the ones
    /// the window's room shows). Consecutive loose rows share a section; a
    /// live workspace the document does not place yet follows last (its
    /// adopt is on the way); one placed in another section (Pinned, a
    /// custom section) lists only as a member of its group there.
    /// `unplacedOrder` orders those last rows (the App's personal order: a new
    /// workspace keeps its press slot while its adopt is on the way); it runs
    /// only when there are some.
    public func sections(_ projection: SidebarDocProjection, session: String, workspaces: [WorkspaceModel],
                         unplacedOrder: ([WorkspaceModel]) -> [WorkspaceModel] = { $0 }) -> [CmuxNextDaemon.SidebarSection] {
        let byResource = Dictionary(workspaces.compactMap { w in w.resourceID.map { ($0.rawValue, w) } }, uniquingKeysWith: { first, _ in first })
        var sections: [CmuxNextDaemon.SidebarSection] = []
        var loose: [WorkspaceModel] = []
        var listed = Set<String>()
        // The groups listed here: a group nested in one that is not lists at the top level.
        var groupsListed = Set<String>()
        func flush() {
            if !loose.isEmpty { sections.append(CmuxNextDaemon.SidebarSection(group: nil, workspaces: loose)) }
            loose = []
        }
        for node in projection.machines[session] ?? [] {
            switch node {
            case .workspace(let ref, _):
                guard let workspace = byResource[ref.workspaceID] else { continue }
                loose.append(workspace)
                listed.insert(workspace.id)
            case .group(let group):
                let members = group.members.compactMap { byResource[$0.workspaceID] }
                // A group lists where it lists a live workspace, or everywhere with none at all; its link, tab and app
                // members follow it (`SidebarDocProjection.arrange`).
                guard !members.isEmpty || group.members.isEmpty else { continue }
                flush()
                listed.formUnion(members.map(\.id))
                var shown = group
                if let parent = group.parent, !groupsListed.contains(parent) { shown.parent = nil }
                groupsListed.insert(group.id)
                sections.append(CmuxNextDaemon.SidebarSection(group: model(shown), workspaces: members))
            case .link:
                continue // a link row has no workspace; the sidebar model lists it (`SidebarDocProjection.arrange`)
            }
        }
        // A group of Pinned or a custom section is mapped with its machine's rows; the sidebar
        // model lists it in that section (`SidebarDocProjection.arrange`).
        flush()
        // A band group lists with a member here, and so does each group it sits in (`workspace-group-nest-v1`).
        let parents = Dictionary(projection.bandGroups.map { ($0.id, $0.parent) }, uniquingKeysWith: { first, _ in first })
        var shown = Set<String>()
        for group in projection.bandGroups where group.members.contains(where: { $0.sessionID == session && byResource[$0.workspaceID] != nil }) {
            var next: String? = group.id
            while let id = next, shown.insert(id).inserted { next = parents[id] ?? nil }
        }
        for group in projection.bandGroups {
            let members = group.members.filter { $0.sessionID == session }.compactMap { byResource[$0.workspaceID] }
            guard shown.contains(group.id) else { continue }
            listed.formUnion(members.map(\.id))
            sections.append(CmuxNextDaemon.SidebarSection(group: model(group), workspaces: members))
        }
        let placed = Set(projection.items.keys.filter { $0.sessionID == session }.map(\.workspaceID))
        let unplaced = workspaces.filter { w in !listed.contains(w.id) && !(w.resourceID.map { placed.contains($0.rawValue) } ?? false) }
        if !unplaced.isEmpty { loose += unplacedOrder(unplaced) }
        flush()
        if sections.isEmpty { sections.append(CmuxNextDaemon.SidebarSection(group: nil, workspaces: [])) }
        return sections
    }

    private func model(_ group: SidebarDocProjection.Group) -> WorkspaceGroupModel {
        let snapshot = WorkspaceGroupSnapshot(id: WorkspaceGroupID(rawValue: group.id), name: group.name, color: group.color,
                                              collapsed: group.collapsed, icon: group.icon, pinned: false,
                                              parentGroup: group.parent.map(WorkspaceGroupID.init(rawValue:)))
        if let model = groups[group.id] {
            model.apply(document: snapshot)
            return model
        }
        let model = WorkspaceGroupModel(document: snapshot)
        groups[group.id] = model
        return model
    }
}

/// The wire values of `DaemonSidebarDocRemote`, decoded off the main actor:
/// `apply`'s ops and `adopt`'s refs grow with the workspaces one drop moves.
nonisolated enum SidebarDocWire {
    @concurrent static func json<T: Decodable & Sendable>(_ type: T.Type, from data: Data) async throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
