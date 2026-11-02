import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import CmuxNextDesign
import Foundation
import Testing

/// The invariant behind #27308's six review rounds: whatever an op does to spaces, groups and pins, every group and
/// every link, tab or app of the sidebar document still lists in at least one space. Base listed all of them in
/// every space; each space owning its pins and groups (leo-workspace design/spaces.md) must never leave one in none.
/// One document (band and machine groups nested, Pinned links, tabs and apps across Default, Work and Play), each op
/// applied through the store's own planning where it has one, then every space's window is listed.
@MainActor @Suite struct SidebarSpaceReachabilityTests {
    typealias Spaces = SidebarSpaceOwnsPinsAndGroupsTests
    static let play = "prof_play"
    static let session = Spaces.session

    /// One item of the document as its JSON.
    static func item(_ id: String, _ section: String, parent: String? = nil, body: [String: Any], room: String? = nil) -> [String: Any] {
        var item: [String: Any] = ["id": id, "section": section, "order": id, "body": body]
        if let parent { item["parent"] = parent }
        if let room { item["extra"] = ["room": room] }
        return item
    }

    static func group(_ id: String, _ section: String, parent: String? = nil, profile: String?) -> [String: Any] {
        var body: [String: Any] = ["type": "group", "name": id]
        if let profile { body["profile"] = profile }
        return item(id, section, parent: parent, body: body)
    }

    static func workspace(_ number: Int, _ section: String, parent: String? = nil) -> [String: Any] {
        item("itm_\(number)", section, parent: parent,
             body: ["type": "workspace", "ref": ["session_id": session, "workspace_id": "ws-\(number)"]])
    }

    /// Pinned: links of Default and Work, a tab of Play, an app of Work, and Work's group `itm_bp` holding Work's group
    /// `itm_bc` with a link. The band: Play's group `itm_cp` holding an unscoped `itm_cc` and Play's `itm_ck`, Default's
    /// empty `itm_ch`, a loose link. This Mac: Work's group `itm_mw` with `ws-1` and Work's empty `itm_mn` (a link in
    /// it), the unscoped empty `itm_mh`, and `ws-2` loose.
    static func items() -> [[String: Any]] {
        let pinned = Spaces.pinned, custom = Spaces.custom, machine = Spaces.machine, work = Spaces.work
        return [
            item("itm_lh", pinned, body: ["type": "url", "url": "https://home.example"]),
            item("itm_lw", pinned, body: ["type": "url", "url": "https://work.example"], room: work),
            item("itm_tp", pinned, body: ["type": "tab", "ref": "tab-1"], room: play),
            item("itm_ap", pinned, body: ["type": "app", "id": "acme.weather"], room: work),
            group("itm_bp", pinned, profile: work),
            group("itm_bc", pinned, parent: "itm_bp", profile: work),
            item("itm_bl", pinned, parent: "itm_bc", body: ["type": "url", "url": "https://kept.example"]),
            group("itm_cp", custom, profile: play),
            group("itm_cc", custom, parent: "itm_cp", profile: nil),
            group("itm_ck", custom, parent: "itm_cp", profile: play),
            group("itm_ch", custom, profile: Spaces.home),
            item("itm_cl", custom, body: ["type": "url", "url": "https://loose.example"]),
            group("itm_mw", machine, profile: work),
            workspace(1, machine, parent: "itm_mw"),
            group("itm_mn", machine, parent: "itm_mw", profile: work),
            item("itm_ml", machine, parent: "itm_mn", body: ["type": "url", "url": "https://nested.example"]),
            group("itm_mh", machine, profile: nil),
            workspace(2, machine),
        ]
    }

    static func document(_ items: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "revision": "3",
            "sections": [
                ["id": Spaces.pinned, "kind": ["type": "pinned"], "region": "top", "order": "a"],
                ["id": Spaces.custom, "kind": ["type": "custom"], "region": "top", "order": "b", "title": "Band"],
                ["id": Spaces.machine, "kind": ["type": "machine", "session_id": session], "order": "c"],
            ],
            // Valid order keys in document order (an id is not one: the reducer refused a change to such a document).
            "items": items.enumerated().map { index, item in
                var item = item
                item["order"] = "a" + String(index + 10)
                return item
            },
        ])
    }

    /// The document as an op leaves it: its items, the spaces that exist, and each space's window's workspaces.
    @MainActor struct State {
        var items = SidebarSpaceReachabilityTests.items()
        var spaces: Set<String> = [Spaces.home, Spaces.work, SidebarSpaceReachabilityTests.play]
        var windows: [String: [Int]] = [Spaces.home: [2], Spaces.work: [1], SidebarSpaceReachabilityTests.play: []]

        func index(_ id: String) -> Int? { items.firstIndex { $0["id"] as? String == id } }

        /// What the reducer does with a `group.update {profile}`, an `item.update {room}` and a `group.create`.
        mutating func apply(_ ops: [[String: Any]]) {
            for op in ops {
                let patch = op["patch"] as? [String: Any] ?? [:]
                switch op["op"] as? String {
                case "group.update":
                    guard let at = index(op["id"] as? String ?? ""), var body = items[at]["body"] as? [String: Any] else { continue }
                    body["profile"] = patch["profile"]
                    items[at]["body"] = body
                case "item.update":
                    guard let at = index(op["id"] as? String ?? "") else { continue }
                    items[at]["extra"] = ["room": patch["room"] as Any]
                case "group.create":
                    let to = op["to"] as? [String: Any] ?? [:]
                    var made = SidebarSpaceReachabilityTests.group(op["id"] as? String ?? "", to["section"] as? String ?? "",
                                                                   parent: to["parent"] as? String, profile: op["profile"] as? String)
                    items.append(made)
                default: Issue.record("an op the test does not apply: \(op)")
                }
            }
        }

        /// `id` and everything under it move to `section`, `id` under `parent` (the reducer's `move` of a subtree).
        mutating func move(_ id: String, to section: String, parent: String? = nil) {
            var moving: Set<String> = [id]
            var grew = true
            while grew {
                grew = false
                for item in items {
                    if let parent = item["parent"] as? String, moving.contains(parent), let child = item["id"] as? String {
                        grew = moving.insert(child).inserted || grew
                    }
                }
            }
            for at in items.indices where moving.contains(items[at]["id"] as? String ?? "") {
                items[at]["section"] = section
            }
            if let at = index(id) { items[at]["parent"] = parent }
        }
    }

    /// The store over `state`'s document, loaded.
    static func store(_ state: State) async throws -> (SidebarDocStore, Spaces.RecordingRemote) {
        let remote = Spaces.RecordingRemote(document: try document(state.items))
        return (try await Spaces.loadedStore(remote), remote)
    }

    /// Every group, link, tab and app no space's window lists.
    static func unlisted(_ state: State) async throws -> [String] {
        let (store, _) = try await store(state)
        let live = [1, 2].map { Spaces.ref("ws-\($0)") }
        let projection = try #require(store.projection(live: live))
        var listed = Set<String>()
        for space in state.spaces {
            let numbers = state.windows[space] ?? []
            let window = [SidebarSection(kind: .machine(Spaces.thisMac),
                                         nodes: numbers.map { .workspace(SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "ws-\($0)")) })]
            var drag = Spaces.drag(room: space)
            drag.spaces = state.spaces
            for node in projection.arrange(window, drag: drag).flatMap(\.nodes) {
                if case let .group(group) = node { listed.insert(group.id.rawValue) }
                if case let .item(item) = node { listed.insert(item.id) }
            }
            let daemon = DaemonStore()
            daemon.apply(snapshot: DaemonTree(workspaces: numbers.map {
                WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil, resourceID: ResourceID(rawValue: "ws-\($0)"), name: "ws-\($0)")
            }))
            for section in SidebarDocSections(document: { nil }).sections(projection, session: session, workspaces: daemon.workspaces,
                                                                           room: space, spaces: state.spaces) {
                if let group = section.group { listed.insert(group.id.rawValue) }
            }
            let layout = projection.layout.scopedToWindow(ownedElsewhere: { _ in false }, room: space, spaces: state.spaces)
            for section in layout.sections where section.content == .items { listed.formUnion(section.items.map(\.id.rawValue)) }
        }
        // A member link, tab or app lists with its group; a top-level one in a machine section lists in every window.
        let records = try SidebarDocRecords(document: document(state.items))
        return records.items.values.filter { item in
            if item.body.workspace != nil || listed.contains(item.id) { return false }
            if case .group = item.body { return true }
            if let parent = item.parent { return !listed.contains(parent) }
            return records.sections[item.section]?.session == nil
        }.map(\.id).sorted()
    }

    /// The ops of Move Group to Space for `group`, as the store sends them.
    static func movingGroup(_ group: String, to room: String, from: String? = nil, in state: State) async throws -> [[String: Any]] {
        let (store, remote) = try await store(state)
        var refused: [String] = []
        store.onRefused = { refused.append($0) }
        store.moveGroup(group, toSpace: room, from: from)
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { !remote.applied.isEmpty || !refused.isEmpty }
        #expect(refused.isEmpty, "Move Group to Space was refused: \(refused)")
        return remote.applied.flatMap { $0 }
    }

    enum Op: String, CaseIterable {
        case none, moveBandGroup, moveMachineGroup, deleteSpaceInto, deleteSpace, renameSpace, pin, unpin, moveWorkspace,
             newSubgroup, nestUnderAnotherSpace
    }

    static func applying(_ op: Op) async throws -> State {
        var state = State()
        switch op {
        case .none, .renameSpace:
            break // a rename keeps the space's id: nothing it owns changes
        case .moveBandGroup:
            state.apply(try await movingGroup("itm_bp", to: play, in: state))
        case .moveMachineGroup:
            state.apply(try await movingGroup("itm_mw", to: play, in: state))
        case .deleteSpaceInto:
            let records = try SidebarDocRecords(document: document(state.items))
            state.apply(SidebarDocStore.spaceOps(from: Spaces.work, into: play, records: records))
            state.spaces.remove(Spaces.work)
            state.windows[play, default: []] += state.windows.removeValue(forKey: Spaces.work) ?? []
        case .deleteSpace:
            state.spaces.remove(Spaces.work)
            state.windows[Spaces.home, default: []] += state.windows.removeValue(forKey: Spaces.work) ?? []
        case .pin:
            let records = try SidebarDocRecords(document: document(state.items))
            state.move("itm_cl", to: Spaces.pinned)
            state.apply(SidebarDocStore.roomOps(moving: ["itm_cl"], into: Spaces.pinned, room: play, records: records))
            state.move("itm_ch", to: Spaces.pinned)
        case .unpin:
            state.move("itm_lw", to: Spaces.custom)
            state.move("itm_bp", to: Spaces.custom)
        case .moveWorkspace:
            state.windows[Spaces.work] = []
            state.windows[play] = [1]
        case .newSubgroup:
            let records = try SidebarDocRecords(document: document(state.items))
            for (parent, id) in [("itm_mw", "itm_new"), ("itm_cp", "itm_new2"), ("itm_bc", "itm_new3")] {
                let plan = SidebarDocSubgroupPlan(parent: GroupID(parent), id: GroupID(id), name: "Sub", color: .palette(.blue), records: records)
                state.apply(try #require(plan.ops, "\(parent): \(String(describing: plan.refusal))"))
            }
        case .nestUnderAnotherSpace:
            state.move("itm_ch", to: Spaces.pinned, parent: "itm_bp")
            state.move("itm_ck", to: Spaces.machine, parent: "itm_mh")
        }
        return state
    }

    /// After every op, every group and every link, tab or app lists in at least one space.
    @Test(arguments: Op.allCases) func everythingStillListsSomewhere(_ op: Op) async throws {
        let state = try await Self.applying(op)
        let unlisted = try await Self.unlisted(state)
        #expect(unlisted.isEmpty, "\(op): listed in no space: \(unlisted)")
    }

    /// Move Group to Space takes the groups under the group that stored its old space along, so a nested Work group
    /// moved with its Work parent to Play is Play's too. One storing another space, or none, keeps it.
    @Test func movingAGroupCarriesItsNestedGroups() async throws {
        var state = State()
        state.items.append(Self.group("itm_bo", Spaces.pinned, parent: "itm_bp", profile: Spaces.home))
        let ops = try await Self.movingGroup("itm_bp", to: Self.play, in: state)
        let moved = ops.filter { $0["op"] as? String == "group.update" }
            .map { "\($0["id"] as? String ?? "") \(($0["patch"] as? [String: Any])?["profile"] as? String ?? "")" }.sorted()
        #expect(moved == ["itm_bc \(Self.play)", "itm_bp \(Self.play)"], "\(ops)")
    }

    /// The review of #27308 at 5e328e3: Move Group to Space on a personal group sends the personal update first (it
    /// moves the workspace pins, and only while the stored space differs), then the document's ops. By then the
    /// group's own space may already read the target (the personal update syncs it); the nested groups that stored
    /// the space it had before the move still go with it.
    @Test func movingAGroupWhoseSpaceAlreadySyncedStillCarriesItsNestedGroups() async throws {
        var state = State()
        state.apply([["op": "group.update", "id": "itm_bp", "patch": ["profile": Self.play]]])
        let ops = try await Self.movingGroup("itm_bp", to: Self.play, from: Spaces.work, in: state)
        let moved = ops.filter { $0["op"] as? String == "group.update" }
            .map { "\($0["id"] as? String ?? "") \(($0["patch"] as? [String: Any])?["profile"] as? String ?? "")" }
        #expect(moved == ["itm_bc \(Self.play)"], "\(ops)")
    }
}
