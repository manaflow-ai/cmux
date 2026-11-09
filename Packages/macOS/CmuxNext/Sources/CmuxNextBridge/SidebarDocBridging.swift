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

    public var isConnected: Bool { connection() != nil }

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
    /// Where the daemon's create puts a new workspace (`workspaces.newPlacement`): first in its machine section
    /// (`top`), right below the window's current workspace (`afterCurrent`, the default; first when there is
    /// none), or last (`bottom`). A live workspace the document does not place yet lists at that slot, so its
    /// item's arrival moves nothing, and none made by the CLI or an agent shows at the sidebar's end first and
    /// then jumps (Leo 2026-11-06; plans/cmux-next/sidebar-ordering-DESIGN.md).
    public enum NewRowsPlace: Hashable, Sendable {
        case first, below(String), last
    }

    public var newRowsPlace: @MainActor () -> NewRowsPlace = { .first }

    /// Whether new rows list first (`top`).
    public func placesNewRowsFirst() -> Bool { newRowsPlace() == .first }

    /// The current workspaces seen per session, latest last (at most `currentsKept`): the anchor of a chain of creates.
    private var currents: [String: [String]] = [:]
    /// Where each workspace last listed per session: its group (nil: a loose run) and the row above it there (nil:
    /// first). A listed workspace the document stops placing for a moment (its item or ref in flight) keeps that slot,
    /// so no row leaves its group or moves (Leo 2026-11-07, a collapsed group's running rows jumping out of it).
    private var slots: [String: [String: Slot]] = [:]
    /// `before`: for a loose row, the group just above its loose run (nil: the machine's first section).
    private struct Slot: Equatable { var group: String?; var after: String?; var before: String? }
    /// The place each new row took when it first listed, per session: a selection change does not move it.
    private var anchors: [String: [String: NewRowsPlace]] = [:]
    private static let currentsKept = 64

    /// Where `session`'s new rows list for `place`, and whether newest first. Below a current workspace that lists,
    /// newest first: the daemon put each right below it. When the current one is itself new (Cmd-N selects each new
    /// workspace, so each went below the one before it), in the order made, below the latest current one that lists.
    /// `lists`: whether a workspace lists already. Call it on every pass, so the anchor is known before a create.
    public func newRows(_ place: NewRowsPlace, session: String, fresh: Set<String>,
                        lists: (String) -> Bool) -> (place: NewRowsPlace, newestFirst: Bool) {
        guard case .below(let current) = place else { return (place, true) }
        var seen = currents[session, default: []]
        if seen.last != current { seen.removeAll { $0 == current }; seen.append(current); currents[session] = Array(seen.suffix(Self.currentsKept)) }
        guard fresh.contains(current) else { return (place, true) }
        return (seen.last(where: lists).map(NewRowsPlace.below) ?? .first, false)
    }

    /// ``newRows(_:session:fresh:lists:)`` for ``newRowsPlace`` over a flat list: `ordered` lists, but not its `fresh` rows.
    public func newRows(session: String, ordered: [WorkspaceModel], fresh: [WorkspaceModel]) -> (place: NewRowsPlace, newestFirst: Bool) {
        let new = Set(fresh.map(\.id)), shown = Set(ordered.map(\.id)).subtracting(new)
        return newRows(newRowsPlace(), session: session, fresh: new, lists: { shown.contains($0) })
    }
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
    /// daemon's create puts it (``newRowsPlace``): first in the machine section,
    /// below a leading Home row and above every group, right below the current workspace, or last. One
    /// placed in another section (Pinned, a custom section) lists only as a
    /// member of its group there. `unplacedOrder` orders those rows (the App's
    /// personal order, newest first under `top`); it runs only when there are some. `room`: the window's space; a
    /// group with no workspace at all lists only in its own space (`Group.lists(inRoom:)`), nil lists it everywhere;
    /// `spaces`: the spaces that exist (one of a gone space is the default space's).
    public func sections(_ projection: SidebarDocProjection, session: String, workspaces: [WorkspaceModel], room: String? = nil,
                         spaces: Set<String>? = nil,
                         unplacedOrder: ([WorkspaceModel]) -> [WorkspaceModel] = { $0 }) -> [CmuxNextDaemon.SidebarSection] {
        let byResource = Dictionary(workspaces.compactMap { w in w.resourceID.map { ($0.rawValue, w) } }, uniquingKeysWith: { first, _ in first })
        var sections: [CmuxNextDaemon.SidebarSection] = []
        var loose: [WorkspaceModel] = []
        var listed = Set<String>()
        func flush() {
            if !loose.isEmpty { sections.append(CmuxNextDaemon.SidebarSection(group: nil, workspaces: loose)) }
            loose = []
        }
        let nodes = projection.machines[session] ?? []
        // A group lists with a group under it that lists a live workspace here (a parent with none of its own too); an
        // empty one, only in its own space and only under a parent that lists. A child never lists without its parent.
        var parentOf: [String: String] = [:]
        for case .group(let group) in nodes { if let parent = group.parent { parentOf[group.id] = parent } }
        var holdsLive = Set<String>()
        for case .group(let group) in nodes where group.members.contains(where: { byResource[$0.workspaceID] != nil }) {
            var id: String? = group.id
            while let current = id, holdsLive.insert(current).inserted { id = parentOf[current] }
        }
        var listedGroups = Set<String>()
        for node in nodes {
            switch node {
            case .workspace(let ref, _):
                guard let workspace = byResource[ref.workspaceID] else { continue }
                loose.append(workspace)
                listed.insert(workspace.id)
            case .group(let group):
                let members = group.members.compactMap { byResource[$0.workspaceID] }
                // A group lists where it or a group under it lists a live workspace, or in its own space with none at
                // all, under a parent that lists; its link, tab and app members follow it (`SidebarDocProjection.arrange`).
                let parentListed = group.parent.map(listedGroups.contains) ?? true
                guard holdsLive.contains(group.id) || (parentListed && group.members.isEmpty && group.lists(inRoom: room, spaces: spaces)) else { continue }
                listedGroups.insert(group.id)
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
        var machineSections = sections.count
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
        var unplaced = workspaces.filter { w in !listed.contains(w.id) && !(w.resourceID.map { placed.contains($0.rawValue) } ?? false) }
        // One that listed before keeps its slot (its group, under the same row) until the document places it again.
        let waiting = holdSlots(unplaced, session: session, in: &sections, machineSections: &machineSections)
        let held = Set(unplaced.map(\.id)).subtracting(waiting.map(\.id))
        unplaced = waiting
        let (place, newestFirst) = newRows(newRowsPlace(), session: session, fresh: Set(unplaced.map(\.id)), lists: { listed.contains($0) })
        // A new row stays where it first listed: the place it took then, not the current workspace now.
        let unplacedIDs = Set(unplaced.map(\.id))
        var firstPlaces = anchors[session, default: [:]].filter { id, _ in unplacedIDs.contains(id) }
        // As the daemon places them: the store lists a new workspace last, and its personal row comes with its item, so
        // the unplaced ones have none to order them by yet.
        let ordered = unplacedOrder(newestFirst ? Array(unplaced.reversed()) : unplaced)
        // A new row made below a chain of new rows still waiting for their items goes under the chain's last row, so a
        // chain of creates keeps its order as their items arrive one at a time. One pass: each chain's start and end.
        var chainEnd: [NewRowsPlace: String] = [:]
        var chainStart: [String: NewRowsPlace] = [:]
        for w in ordered {
            if firstPlaces[w.id] == nil {
                if case .below = place, !newestFirst, let end = chainEnd[place] { firstPlaces[w.id] = .below(end) } else { firstPlaces[w.id] = place }
            }
            guard let at = firstPlaces[w.id] else { continue }
            var start = at
            if case .below(let id) = at, let of = chainStart[id] { start = of }
            chainStart[w.id] = start
            chainEnd[start] = w.id
        }
        anchors[session] = firstPlaces
        let tail = unplaced.filter { firstPlaces[$0.id] == .last }
        if !tail.isEmpty { loose += unplacedOrder(tail) }
        let rest = ordered.filter { firstPlaces[$0.id] != .last }
        if !rest.isEmpty {
            // One run per place among listed rows; a row anchored under another new row joins that row's run right
            // under it (a row listed later in `rest`, as newest first lists it, takes the ones waiting under it along).
            let newIDs = Set(rest.map(\.id))
            var runs: [(NewRowsPlace, [WorkspaceModel])] = []
            var runAt: [NewRowsPlace: Int] = [:]
            var runOf: [String: Int] = [:]
            var waitingUnder: [String: [WorkspaceModel]] = [:]
            func add(_ w: WorkspaceModel) {
                let at = firstPlaces[w.id] ?? place
                if case .below(let id) = at, newIDs.contains(id) {
                    guard let i = runOf[id] else { waitingUnder[id, default: []].append(w); return }
                    let after = runs[i].1.last?.id == id ? runs[i].1.count : (runs[i].1.firstIndex { $0.id == id } ?? runs[i].1.count - 1) + 1
                    runs[i].1.insert(w, at: after)
                    runOf[w.id] = i
                } else if let i = runAt[at] {
                    runs[i].1.append(w)
                    runOf[w.id] = i
                } else {
                    runAt[at] = runs.count
                    runOf[w.id] = runs.count
                    runs.append((at, [w]))
                }
                for next in waitingUnder.removeValue(forKey: w.id) ?? [] { add(next) }
            }
            for w in rest { add(w) }
            // Rows under a row that never listed (a cycle): at the new-row place.
            for w in rest where runOf[w.id] == nil {
                firstPlaces[w.id] = place
                add(w)
            }
            var machineCount = machineSections
            for (at, rows) in runs {
                let count = sections.count
                Self.insertNew(rows, at, into: &sections, machineSections: machineCount)
                machineCount += sections.count - count // a run listed first can open a loose section on top
            }
        }
        flush()
        noteSlots(sections, session: session, placed: listed, held: held)
        if sections.isEmpty { sections.append(CmuxNextDaemon.SidebarSection(group: nil, workspaces: [])) }
        return sections
    }

    /// Puts each of `unplaced` that listed before back in its slot among the machine's rows (the first `machineSections`
    /// of `sections`): under the row it was under, in the same group (or loose run). Returns the ones with no slot to
    /// go back to. Rows go back in a chain (one under another held one), so a run of them keeps its order.
    private func holdSlots(_ unplaced: [WorkspaceModel], session: String, in sections: inout [CmuxNextDaemon.SidebarSection],
                           machineSections: inout Int) -> [WorkspaceModel] {
        let known = slots[session] ?? [:]
        var waiting = unplaced.filter { known[$0.id] != nil }
        var held = Set<String>() // only rows put back: a row with no slot (a new one) is no row's to hold
        guard !waiting.isEmpty else { return unplaced }
        var progress = true
        while progress && !waiting.isEmpty {
            progress = false
            for w in waiting {
                guard let slot = known[w.id] else { continue }
                let machine = sections.indices.prefix(machineSections)
                let found: Int?
                if slot.group == nil && slot.after == nil {
                    // First in its loose run: the run under the same group, else the run opens again there.
                    found = machine.first { i in sections[i].group == nil && (i == 0 ? nil : sections[i - 1].group?.id.rawValue) == slot.before }
                    if found == nil {
                        let at = slot.before.flatMap { group in machine.first { sections[$0].group?.id.rawValue == group } }.map { $0 + 1 } ?? 0
                        sections.insert(CmuxNextDaemon.SidebarSection(group: nil, workspaces: [w]), at: at)
                        machineSections += 1
                        waiting.removeAll { $0.id == w.id }
                        held.insert(w.id)
                        progress = true
                        continue
                    }
                } else {
                    found = machine.first { i in
                        sections[i].group?.id.rawValue == slot.group
                            && (slot.after.map { after in sections[i].workspaces.contains { $0.id == after } } ?? true)
                    }
                }
                guard let index = found else { continue }
                var rows = sections[index].workspaces
                let at = slot.after.flatMap { after in rows.firstIndex { $0.id == after } }.map { $0 + 1 } ?? 0
                rows.insert(w, at: at)
                sections[index] = CmuxNextDaemon.SidebarSection(group: sections[index].group, workspaces: rows)
                waiting.removeAll { $0.id == w.id }
                held.insert(w.id)
                progress = true
            }
        }
        return unplaced.filter { !held.contains($0.id) }
    }

    /// Records where each row the document places lists now, for ``holdSlots``; a `held` row keeps the slot it had. A
    /// new row (no item yet) gets none: it keeps the place it first took (`anchors`), and is no row's `after`.
    private func noteSlots(_ sections: [CmuxNextDaemon.SidebarSection], session: String, placed: Set<String>, held: Set<String>) {
        let old = slots[session] ?? [:]
        var next: [String: Slot] = [:]
        next.reserveCapacity(placed.count + held.count)
        var groupAbove: String?
        for section in sections {
            var above: String?
            let before = section.group == nil ? groupAbove : nil
            groupAbove = section.group?.id.rawValue
            for w in section.workspaces {
                if held.contains(w.id) {
                    next[w.id] = old[w.id]
                } else if placed.contains(w.id) {
                    next[w.id] = Slot(group: section.group?.id.rawValue, after: above, before: before)
                } else {
                    continue
                }
                above = w.id
            }
        }
        slots[session] = next
    }

    /// Puts `rows` where `place` lists new rows among the machine's rows (the first `machineSections` of
    /// `sections`): right below workspace `current` in its section (its group, else its loose run), as the
    /// daemon's `afterCurrent` create does, else first (``insertFirst(_:into:machineSections:)``). The caller
    /// lists `.last` rows itself.
    public static func insertNew(_ rows: [WorkspaceModel], _ place: NewRowsPlace, into sections: inout [CmuxNextDaemon.SidebarSection],
                                 machineSections: Int) {
        for index in sections.indices.prefix(machineSections) {
            guard case .below(let current) = place, let at = sections[index].workspaces.firstIndex(where: { $0.id == current }) else { continue }
            var workspaces = sections[index].workspaces
            workspaces.insert(contentsOf: rows, at: at + 1)
            sections[index] = CmuxNextDaemon.SidebarSection(group: sections[index].group, workspaces: workspaces)
            return
        }
        insertFirst(rows, into: &sections, machineSections: machineSections)
    }

    /// `fresh` (new workspaces, in the order they list) placed into the flat `ordered` list where `place` puts
    /// them: first below a leading Home row, right below `current`, or last.
    public static func insertNew(_ fresh: [WorkspaceModel], _ place: NewRowsPlace, into ordered: [WorkspaceModel]) -> [WorkspaceModel] {
        var placed = ordered
        if place == .last { return placed + fresh }
        if case .below(let current) = place, let at = placed.firstIndex(where: { $0.id == current }) {
            placed.insert(contentsOf: fresh, at: at + 1)
        } else {
            placed.insert(contentsOf: fresh, at: placed.first?.kind == SidebarMapping.homeKind ? 1 : 0)
        }
        return placed
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
