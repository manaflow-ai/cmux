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
    /// Whether the daemon puts a new workspace first in its machine section (`workspaces.newPlacement`
    /// `top`, the default); false lists it last, as `bottom` does (`afterCurrent` keeps a pending row
    /// at the window's slot meanwhile). A live workspace the document does not place
    /// yet lists at that slot, so its item's arrival moves nothing (plans/cmux-next/sidebar-ordering-DESIGN.md).
    public var placesNewRowsFirst: @MainActor () -> Bool = { true }
    /// The app's own document store (its confirmed folds, its shown projection); nil before it starts.
    let document: @MainActor () -> SidebarDocStore?

    public init(document: @escaping @MainActor () -> SidebarDocStore?) {
        self.document = document
    }

    /// The document ref of `workspace` on the session `session`.
    public static func ref(of workspace: WorkspaceModel, session: String?) -> SidebarDocWorkspaceRef? {
        guard let session, let resource = workspace.resourceID?.rawValue else { return nil }
        return SidebarDocWorkspaceRef(sessionID: session, workspaceID: resource)
    }

    /// `session`'s sections in document order over `workspaces` (the ones
    /// the window's room shows). Consecutive loose rows share a section; a
    /// live workspace the document does not place yet (a new one: its item
    /// comes on `session.events`, after `workspace-added`) lists where the
    /// daemon's create puts it: first in the machine section, below a leading
    /// Home row and above every group (``placesNewRowsFirst``), else last. One
    /// placed in another section (Pinned, a custom section) lists only as a
    /// member of its group there. `unplacedOrder` orders those rows (the App's
    /// personal order, newest first under `top`); it runs only when there are some.
    public func sections(_ projection: SidebarDocProjection, session: String, workspaces: [WorkspaceModel],
                         unplacedOrder: ([WorkspaceModel]) -> [WorkspaceModel] = { $0 }) -> [CmuxNextDaemon.SidebarSection] {
        let byResource = Dictionary(workspaces.compactMap { w in w.resourceID.map { ($0.rawValue, w) } }, uniquingKeysWith: { first, _ in first })
        var sections: [CmuxNextDaemon.SidebarSection] = []
        var loose: [WorkspaceModel] = []
        var listed = Set<String>()
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
                sections.append(CmuxNextDaemon.SidebarSection(group: model(group), workspaces: members))
            case .link:
                continue // a link row has no workspace; the sidebar model lists it (`SidebarDocProjection.arrange`)
            }
        }
        // A group of Pinned or a custom section is mapped with its machine's rows; the sidebar
        // model lists it in that section (`SidebarDocProjection.arrange`).
        flush()
        let machineSections = sections.count
        // A band group lists with this machine's rows when it or a group under it holds one of them.
        let bandMembers = projection.bandGroups.map { group in
            group.members.filter { $0.sessionID == session }.compactMap { byResource[$0.workspaceID] }
        }
        var shownBand = Set<String>()
        for (group, members) in zip(projection.bandGroups, bandMembers) where !members.isEmpty {
            var id: String? = group.id
            while let current = id, shownBand.insert(current).inserted {
                id = projection.bandGroups.first { $0.id == current }?.parent
            }
        }
        for (group, members) in zip(projection.bandGroups, bandMembers) where shownBand.contains(group.id) {
            listed.formUnion(members.map(\.id))
            sections.append(CmuxNextDaemon.SidebarSection(group: model(group), workspaces: members))
        }
        let placed = Set(projection.items.keys.filter { $0.sessionID == session }.map(\.workspaceID))
        let unplaced = workspaces.filter { w in !listed.contains(w.id) && !(w.resourceID.map { placed.contains($0.rawValue) } ?? false) }
        if !unplaced.isEmpty {
            if placesNewRowsFirst() {
                // Newest first, as the daemon places them: the store lists a new workspace last, and its
                // personal row comes with its item, so the unplaced ones have none to order them by yet.
                Self.insertFirst(unplacedOrder(Array(unplaced.reversed())), into: &sections, machineSections: machineSections)
            } else {
                loose += unplacedOrder(unplaced)
            }
        }
        flush()
        if sections.isEmpty { sections.append(CmuxNextDaemon.SidebarSection(group: nil, workspaces: [])) }
        return sections
    }

    /// Puts `rows` first among the machine's rows (the first `machineSections` of `sections`): after a
    /// leading Home row, in the first loose run, or as a loose run of their own above a leading group.
    ///
    /// - Parameters:
    ///   - rows: The new workspaces, in the order they list (newest first under `top`).
    ///   - sections: One machine's sections; the machine's own come first.
    ///   - machineSections: How many of `sections` are the machine's own (band groups follow them).
    public static func insertFirst(_ rows: [WorkspaceModel], into sections: inout [CmuxNextDaemon.SidebarSection], machineSections: Int) {
        if machineSections > 0, sections[0].group == nil {
            var workspaces = sections[0].workspaces
            let skip = workspaces.first?.kind == SidebarMapping.homeKind ? 1 : 0
            workspaces.insert(contentsOf: rows, at: skip)
            sections[0] = CmuxNextDaemon.SidebarSection(group: nil, workspaces: workspaces)
        } else {
            sections.insert(CmuxNextDaemon.SidebarSection(group: nil, workspaces: rows), at: 0)
        }
    }

    private func model(_ group: SidebarDocProjection.Group) -> WorkspaceGroupModel {
        let snapshot = WorkspaceGroupSnapshot(id: WorkspaceGroupID(rawValue: group.id), name: group.name, color: group.color,
                                              collapsed: document()?.groupFolds[group.id] ?? group.collapsed,
                                              icon: group.icon, pinned: group.pinned,
                                              parent: group.parent.map(WorkspaceGroupID.init(rawValue:)), depth: group.depth)
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
