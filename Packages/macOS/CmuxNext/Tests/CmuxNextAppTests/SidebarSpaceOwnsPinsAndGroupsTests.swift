import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import CmuxNextDesign
import Foundation
import Testing

/// Leo 2026-10-29: "could u guys also now work on the per space pins and groups? rn anything u make in teh default space
/// goes across to new ones". Each space owns its pins and groups (leo-workspace design/spaces.md): a group stores the
/// space it was made in (`profile`), a link, tab or app pinned to Pinned stores it too (`extra.room`), and a window draws
/// them only in that space. What was made before items stored a space is the default space's. A pinned workspace's
/// space is its own (spaces-overhaul-DESIGN.md rule 1, `SidebarRows.bandHides`), and a group lists wherever one of its
/// open workspaces lists, as before.
@MainActor @Suite struct SidebarSpaceOwnsPinsAndGroupsTests {
    static let session = "s-local"
    static let machine = "sec_m_s-local"
    static let custom = "sec_custom"
    static let pinned = "sec_pinned"
    static let work = "prof_work"
    static let home = SidebarDocItem.defaultRoom

    static func ref(_ id: String) -> SidebarDocWorkspaceRef { SidebarDocWorkspaceRef(sessionID: session, workspaceID: id) }

    static func group(_ id: String, _ section: String, room: String?) -> SidebarDocItem {
        SidebarDocItem(id: id, section: section, body: .group(name: id, color: nil, icon: nil, collapsed: false), room: room)
    }

    /// Pinned: link `itm_lw` made in Work, link `itm_lo` made before items stored a space, empty group `itm_gw` made
    /// in Work. Work: empty group `itm_gc` made in Work, empty group `itm_go` with no space, group `itm_gl` (no space)
    /// whose open workspace `ws-9` lists in Work. This Mac: `ws-1`.
    static func projection() -> SidebarDocProjection {
        let records = SidebarDocRecords(sections: [
            pinned: SidebarDocSection(id: pinned, kind: .pinned, region: .top),
            custom: SidebarDocSection(id: custom, kind: .custom, title: "Work"),
            machine: SidebarDocSection(id: machine, kind: .machine(session: session)),
        ], items: [
            "itm_lw": SidebarDocItem(id: "itm_lw", section: pinned, body: .url("https://work.example", title: "Work"), room: work),
            "itm_lo": SidebarDocItem(id: "itm_lo", section: pinned, body: .url("https://old.example", title: "Old")),
            "itm_gw": group("itm_gw", pinned, room: work),
            "itm_gc": group("itm_gc", custom, room: work),
            "itm_go": group("itm_go", custom, room: nil),
            "itm_gl": group("itm_gl", custom, room: nil),
            "itm_9": SidebarDocItem(id: "itm_9", section: custom, parent: "itm_gl", body: .workspace(ref("ws-9"))),
            "itm_1": SidebarDocItem(id: "itm_1", section: machine, body: .workspace(ref("ws-1"))),
        ])
        let rows = [
            SidebarDocRow(key: "itm_lw", kind: "url", section: pinned, item: "itm_lw"),
            SidebarDocRow(key: "itm_lo", kind: "url", section: pinned, item: "itm_lo"),
            SidebarDocRow(key: "itm_gw", kind: "group", section: pinned, item: "itm_gw"),
            SidebarDocRow(key: "itm_gc", kind: "group", section: custom, item: "itm_gc"),
            SidebarDocRow(key: "itm_go", kind: "group", section: custom, item: "itm_go"),
            SidebarDocRow(key: "itm_gl", kind: "group", section: custom, item: "itm_gl"),
            SidebarDocRow(key: "itm_9", kind: "item", section: custom, parent: "itm_gl", depth: 1, item: "itm_9", ref: ref("ws-9")),
            SidebarDocRow(key: "itm_1", kind: "item", section: machine, item: "itm_1", ref: ref("ws-1")),
        ]
        return SidebarDocProjection(rows: rows, records: records, revision: 1)
    }

    static let thisMac = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    static func drag(room: String?) -> SidebarDocDrag {
        var drag = SidebarDocDrag(item: { key in
            if case let .workspace(id) = key { return "itm_" + id.rawValue.dropFirst(3) }
            return nil
        }, section: { id in id == .machine(.local) ? machine : nil }, begin: { _ in [:] }, drop: { _, _ in })
        drag.listedElsewhere = { _ in false }
        drag.room = room
        return drag
    }

    static func groupIDs(room: String?) -> Set<String> {
        let window = [SidebarSection(kind: .machine(thisMac), nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("ws-1"), title: "ws-1"))])]
        let arranged = projection().arrange(window, drag: drag(room: room))
        return Set(arranged.flatMap(\.nodes).compactMap { if case let .group(group) = $0 { group.id.rawValue } else { nil } })
    }

    static func pinnedLinks(room: String) -> [String] {
        let layout = projection().layout.scopedToWindow(ownedElsewhere: { _ in false }, room: room)
        return layout.section(SidebarLayoutDocument.pinnedSectionID)?.items.map(\.id.rawValue) ?? []
    }

    /// A new space starts with none of the default space's groups; each space draws its own.
    @Test func aGroupDrawsOnlyInTheSpaceItWasMadeIn() {
        #expect(Self.groupIDs(room: Self.work) == ["itm_gw", "itm_gc"], "\(Self.groupIDs(room: Self.work))")
        #expect(Self.groupIDs(room: Self.home) == ["itm_go"], "\(Self.groupIDs(room: Self.home))")
    }

    /// No space filter (no window space): every group draws, as before spaces owned them.
    @Test func withoutASpaceEveryGroupDraws() {
        #expect(Self.groupIDs(room: nil) == ["itm_gw", "itm_gc", "itm_go", "itm_gl"])
    }

    /// A group listing an open workspace of this window lists here whatever space it stores: its workspace's space wins.
    @Test func aGroupListsWhereItsOpenWorkspaceLists() {
        let ws9 = SidebarWorkspace(id: WorkspaceID("ws-9"), title: "ws-9")
        let window = [SidebarSection(kind: .machine(Self.thisMac), nodes: [.group(SidebarGroup(id: GroupID("itm_gl"), name: "itm_gl", workspaces: [ws9]))])]
        let arranged = Self.projection().arrange(window, drag: Self.drag(room: Self.work))
        let ids = Set(arranged.flatMap(\.nodes).compactMap { if case let .group(group) = $0 { group.id.rawValue } else { nil } })
        #expect(ids.contains("itm_gl"), "\(ids)")
    }

    /// A link pinned in Work draws in Work only; one pinned before links stored a space is the default space's.
    @Test func aPinnedLinkDrawsOnlyInItsSpace() {
        #expect(Self.pinnedLinks(room: Self.work) == ["itm_lw"])
        #expect(Self.pinnedLinks(room: Self.home) == ["itm_lo"])
    }

    /// The band's change check sees a space switch: the groups it leaves out change with the window's space.
    @Test func theGroupsLeftOutFollowTheWindowsSpace() {
        let projection = Self.projection()
        #expect(projection.bandGroupsNotListedHere(drag: Self.drag(room: Self.work))
            != projection.bandGroupsNotListedHere(drag: Self.drag(room: Self.home)))
    }

    /// A group nested under another space's group leaves with its parent: a window never draws a child group whose
    /// parent it leaves out. Work's group `itm_gk` sits under the default space's group `itm_gp`.
    @Test func aNestedGroupLeavesWithItsParentsSpace() {
        let records = SidebarDocRecords(sections: [
            Self.custom: SidebarDocSection(id: Self.custom, kind: .custom, title: "Work"),
            Self.machine: SidebarDocSection(id: Self.machine, kind: .machine(session: Self.session)),
        ], items: [
            "itm_gp": Self.group("itm_gp", Self.custom, room: nil),
            "itm_gk": SidebarDocItem(id: "itm_gk", section: Self.custom, parent: "itm_gp",
                                     body: .group(name: "itm_gk", color: nil, icon: nil, collapsed: false), room: Self.work),
            "itm_1": SidebarDocItem(id: "itm_1", section: Self.machine, body: .workspace(Self.ref("ws-1"))),
        ])
        let rows = [
            SidebarDocRow(key: "itm_gp", kind: "group", section: Self.custom, item: "itm_gp"),
            SidebarDocRow(key: "itm_gk", kind: "group", section: Self.custom, parent: "itm_gp", depth: 1, item: "itm_gk"),
            SidebarDocRow(key: "itm_1", kind: "item", section: Self.machine, item: "itm_1", ref: Self.ref("ws-1")),
        ]
        let projection = SidebarDocProjection(rows: rows, records: records, revision: 1)
        let window = [SidebarSection(kind: .machine(Self.thisMac), nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("ws-1"), title: "ws-1"))])]
        func groups(_ room: String) -> Set<String> {
            let arranged = projection.arrange(window, drag: Self.drag(room: room))
            return Set(arranged.flatMap(\.nodes).compactMap { if case let .group(group) = $0 { group.id.rawValue } else { nil } })
        }
        #expect(groups(Self.work).isEmpty, "\(groups(Self.work))")
        #expect(groups(Self.home) == ["itm_gp"], "\(groups(Self.home))")
    }

    /// The wire: a group's space is its body's `profile`, another item's is `extra.room`.
    @Test func theSpaceIsReadFromTheWire() throws {
        let group = Data(#"{"id":"itm_g","section":"sec_custom","body":{"type":"group","name":"G","profile":"prof_work"}}"#.utf8)
        let link = Data(#"{"id":"itm_l","section":"sec_pinned","body":{"type":"url","url":"https://a.example"},"extra":{"room":"prof_work"}}"#.utf8)
        let old = Data(#"{"id":"itm_o","section":"sec_pinned","body":{"type":"url","url":"https://b.example"}}"#.utf8)
        #expect(try JSONDecoder().decode(SidebarDocWire.Item.self, from: group).record.room == Self.work)
        #expect(try JSONDecoder().decode(SidebarDocWire.Item.self, from: link).record.room == Self.work)
        #expect(try JSONDecoder().decode(SidebarDocWire.Item.self, from: old).record.room == nil)
    }

    /// New Group stores the window's space on the group.
    @Test func aNewGroupStoresTheWindowsSpace() throws {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        let intent = SidebarIntent.createGroup(GroupID("grp_new"), name: "New", color: .blue, workspaces: [])
        let ops = try #require(store.groupOps(intent, room: Self.work, items: { _ in [] })?.ops)
        #expect(ops.first?["profile"] as? String == Self.work, "\(ops)")
    }

    /// A link pinned to Pinned stores the acting window's space; one added to another band stores none.
    @Test func aPinnedLinkStoresTheActingWindowsSpace() throws {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        store.newItemRoom = { Self.work }
        let link = LayoutItem(id: LayoutItemID("itm_new"), ref: .url("https://new.example"))
        let layout = SidebarLayoutDocument.defaults
        let pin = try #require(layout.pinOp(link.ref, newItem: link.id))
        let ops = try store.docOps(for: [pin], layout: layout)
        let add = try #require(ops.first { $0["op"] as? String == "item.add" }, "\(ops)")
        let item = try #require(add["item"] as? [String: Any])
        #expect((item["extra"] as? [String: String])?["room"] == Self.work, "\(item)")

        let top = try #require(layout.addToTopOp(link.ref, newItem: link.id))
        let topOps = try store.docOps(for: [top], layout: layout)
        let topAdd = try #require(topOps.first { $0["op"] as? String == "item.add" }, "\(topOps)")
        #expect((topAdd["item"] as? [String: Any])?["extra"] == nil, "\(topAdd)")
    }

    /// A link in a custom band (`sec_custom`) that stores no space, Pinned, and This Mac.
    static let linkDocument = Data("""
    {"revision": "3",
     "sections": [
       {"id": "sec_pinned", "kind": {"type": "pinned"}, "region": "top", "order": "a"},
       {"id": "sec_custom", "kind": {"type": "custom"}, "region": "top", "order": "b", "title": "Links"},
       {"id": "sec_m_s-local", "kind": {"type": "machine", "session_id": "s-local"}, "order": "c"}
     ],
     "items": [
       {"id": "itm_l", "section": "sec_custom", "order": "a", "body": {"type": "url", "url": "https://work.example"}},
       {"id": "itm_1", "section": "sec_m_s-local", "order": "a",
        "body": {"type": "workspace", "ref": {"session_id": "s-local", "workspace_id": "ws-1"}}}
     ]}
    """.utf8)

    /// A daemon that keeps every change it is sent and never answers (the change stays pending, as on a round trip).
    @MainActor final class RecordingRemote: SidebarDocRemote {
        let document: Data
        private(set) var applied: [[[String: Any]]] = []
        private(set) var moved: [[String]] = []
        init(document: Data) { self.document = document }
        var isAvailable: Bool { true }
        func get() async throws -> Data { document }
        func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply {
            moved.append(items)
            return try await unanswered()
        }
        func pin(_ items: [String], key: String) async throws -> SidebarDocReply { try await unanswered() }
        func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { try await unanswered() }
        func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply { try await unanswered() }
        func apply(ops: Data, key: String) async throws -> SidebarDocReply {
            applied.append((try? JSONSerialization.jsonObject(with: ops) as? [[String: Any]]) ?? [])
            return try await unanswered()
        }
        private func unanswered() async throws -> SidebarDocReply {
            try await Task.sleep(for: .seconds(600))
            throw CancellationError()
        }
    }

    static func loadedStore(_ remote: RecordingRemote) async throws -> SidebarDocStore {
        let store = SidebarDocStore(remote: remote)
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive }
        try #require(store.isActive, "the store did not load the document")
        return store
    }

    static func roomUpdate(_ ops: [[String: Any]], item: String) -> String? {
        ops.first { $0["op"] as? String == "item.update" && $0["id"] as? String == item }
            .flatMap { ($0["patch"] as? [String: Any])?["room"] as? String }
    }

    /// A link already in another band, moved into Pinned (the band's Move to Pinned), stores the acting window's
    /// space in the same change: without it the projection reads it as the default space's, and in Work it would
    /// vanish from Work and show in Default. One moved into another band stores none.
    @Test func anExistingLinkMovedIntoPinnedTakesTheActingSpace() async throws {
        let store = try await Self.loadedStore(RecordingRemote(document: Self.linkDocument))
        store.newItemRoom = { Self.work }
        let ops = try store.docOps(for: [.itemMove(LayoutItemID("itm_l"), section: SidebarLayoutDocument.pinnedSectionID, index: 0)],
                                   layout: .defaults)
        #expect(ops.contains { $0["op"] as? String == "move" }, "\(ops)")
        #expect(Self.roomUpdate(ops, item: "itm_l") == Self.work, "\(ops)")

        let other = try store.docOps(for: [.itemMove(LayoutItemID("itm_l"), section: LayoutSectionID("sec_top"), index: 0)],
                                     layout: .defaults)
        #expect(Self.roomUpdate(other, item: "itm_l") == nil, "\(other)")
    }

    /// A link dragged into Pinned (the document drag's drop) stores the acting window's space in the same change.
    /// The daemon gets the ops as the app FFI's reducer stamps them: one pinned before `item.update` took `room` sends
    /// that update with an empty patch (a no-op), so the space itself is checked where the store plans the change.
    @Test func aLinkDraggedIntoPinnedTakesTheActingSpace() async throws {
        let remote = RecordingRemote(document: Self.linkDocument)
        let store = try await Self.loadedStore(remote)
        store.newItemRoom = { Self.work }
        let target = SidebarDocTarget(section: Self.pinned)
        let planned = try #require(store.spaceKeepingMove(["itm_l"], to: target), "a move into Pinned planned no space")
        #expect(Self.roomUpdate(planned, item: "itm_l") == Self.work, "\(planned)")
        #expect(store.spaceKeepingMove(["itm_l"], to: SidebarDocTarget(section: "sec_top")) == nil)

        store.move(["itm_l"], to: target, title: SidebarDocStore.moveTitle)
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { !remote.applied.isEmpty || !remote.moved.isEmpty }
        let sent = remote.applied.flatMap { $0 }
        let updated = sent.contains { $0["op"] as? String == "item.update" && $0["id"] as? String == "itm_l" }
        #expect(sent.contains { $0["op"] as? String == "move" } && updated,
                "the move and its update go in one change: applied \(remote.applied), moved \(remote.moved)")
    }

    /// The review of #27308: a link moved into Pinned from the Work window stays in Work's Pinned before the daemon
    /// echoes the change. The move's `item.update {room}` is a pending record write: without it the optimistic view
    /// read the link's old space (none, so Default's) and the link left the acting window until the echo.
    @Test func aLinkMovedIntoPinnedStaysInTheActingSpaceBeforeTheEcho() async throws {
        let store = try await Self.loadedStore(RecordingRemote(document: Self.linkDocument))
        store.newItemRoom = { Self.work }
        store.move(["itm_l"], to: SidebarDocTarget(section: Self.pinned), title: SidebarDocStore.moveTitle)
        #expect(store.shownRecords.items["itm_l"]?.room == Self.work, "\(String(describing: store.shownRecords.items["itm_l"]))")
        let projection = try #require(store.projection(live: [Self.ref("ws-1")]))
        func pinned(_ room: String) -> [String] {
            projection.layout.scopedToWindow(ownedElsewhere: { _ in false }, room: room)
                .section(SidebarLayoutDocument.pinnedSectionID)?.items.map(\.id.rawValue) ?? []
        }
        #expect(pinned(Self.work) == ["itm_l"], "the acting space lost the link before the echo: \(pinned(Self.work))")
        #expect(pinned(Self.home).isEmpty, "\(pinned(Self.home))")
    }

    static func pendingOps(_ ops: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: ops) }

    /// A pending `item.update` writes the item fields it patches on the shown records (its space first); a JSON null
    /// clears one, and a patch with none of them writes nothing.
    @Test func aPendingItemUpdateWritesItsFields() throws {
        let records = SidebarDocRecords(sections: [
            Self.pinned: SidebarDocSection(id: Self.pinned, kind: .pinned, region: .top),
        ], items: [
            "itm_l": SidebarDocItem(id: "itm_l", section: Self.pinned, body: .url("https://a.example", title: nil), label: "Old"),
        ])
        var pending = SidebarDocPendingRecords()
        let wrote = pending.add(key: "k1", ops: try Self.pendingOps([
            ["op": "move", "items": ["itm_l"], "to": ["section": Self.pinned]],
            ["op": "item.update", "id": "itm_l", "patch": ["room": Self.work, "label": NSNull(), "shows_label": false]],
        ]), records: records)
        #expect(wrote)
        let item = try #require(pending.applied(to: records).items["itm_l"])
        #expect(item.room == Self.work && item.label == nil && item.showsLabel == false, "\(item)")

        var empty = SidebarDocPendingRecords()
        #expect(!empty.add(key: "k2", ops: try Self.pendingOps([["op": "item.update", "id": "itm_l", "patch": [String: Any]()]]), records: records))
    }

    /// A pending New Group keeps its space (`profile`): made in Work, it draws in Work before the echo.
    @Test func aPendingNewGroupKeepsItsSpace() throws {
        let records = SidebarDocRecords(sections: [
            Self.custom: SidebarDocSection(id: Self.custom, kind: .custom, title: "Work"),
        ], items: [:])
        var pending = SidebarDocPendingRecords()
        pending.add(key: "k1", ops: try Self.pendingOps([
            ["op": "group.create", "id": "itm_gn", "name": "New", "color": "blue", "items": [String](),
             "profile": Self.work, "to": ["section": Self.custom]],
        ]), records: records)
        #expect(pending.applied(to: records).items["itm_gn"]?.room == Self.work)
    }

    /// This Mac's section: `itm_mp` (no space stored, no workspace of its own) holds `itm_mc` (Work's, workspace `ws-5`
    /// live here) and `itm_me` (Work's, empty); `itm_mo` (Default's, empty) holds `itm_mk` (Work's, empty).
    static func machineGroups() -> SidebarDocProjection {
        let records = SidebarDocRecords(sections: [
            machine: SidebarDocSection(id: machine, kind: .machine(session: session)),
        ], items: [
            "itm_mp": group("itm_mp", machine, room: nil),
            "itm_mc": SidebarDocItem(id: "itm_mc", section: machine, parent: "itm_mp",
                                     body: .group(name: "itm_mc", color: nil, icon: nil, collapsed: false), room: work),
            "itm_5": SidebarDocItem(id: "itm_5", section: machine, parent: "itm_mc", body: .workspace(ref("ws-5"))),
            "itm_me": SidebarDocItem(id: "itm_me", section: machine, parent: "itm_mp",
                                     body: .group(name: "itm_me", color: nil, icon: nil, collapsed: false), room: work),
            "itm_mo": group("itm_mo", machine, room: home),
            "itm_mk": SidebarDocItem(id: "itm_mk", section: machine, parent: "itm_mo",
                                     body: .group(name: "itm_mk", color: nil, icon: nil, collapsed: false), room: work),
        ])
        let rows = [
            SidebarDocRow(key: "itm_mp", kind: "group", section: machine, item: "itm_mp"),
            SidebarDocRow(key: "itm_mc", kind: "group", section: machine, parent: "itm_mp", depth: 1, item: "itm_mc"),
            SidebarDocRow(key: "itm_5", kind: "item", section: machine, parent: "itm_mc", depth: 2, item: "itm_5", ref: ref("ws-5")),
            SidebarDocRow(key: "itm_me", kind: "group", section: machine, parent: "itm_mp", depth: 1, item: "itm_me"),
            SidebarDocRow(key: "itm_mo", kind: "group", section: machine, item: "itm_mo"),
            SidebarDocRow(key: "itm_mk", kind: "group", section: machine, parent: "itm_mo", depth: 1, item: "itm_mk"),
        ]
        return SidebarDocProjection(rows: rows, records: records, revision: 1)
    }

    /// The machine section's groups a window on `room` lists, each with its parent.
    static func machineGroupRows(room: String) -> [String: String?] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil,
                                                                        resourceID: ResourceID(rawValue: "ws-5"), name: "ws-5")]))
        let sections = SidebarDocSections().sections(machineGroups(), session: session, workspaces: store.workspaces, room: room)
        return Dictionary(sections.compactMap { section in section.group.map { ($0.id.rawValue, $0.parent?.rawValue) } },
                          uniquingKeysWith: { first, _ in first })
    }

    /// A machine section never lists a group without its parent: a parent with no space stored lists where a group
    /// under it lists a workspace, and an empty group of this space under another space's group leaves with it.
    @Test func aMachineSectionGroupListsWithItsParent() {
        let work = Self.machineGroupRows(room: Self.work)
        for (id, parent) in work { if let parent { #expect(work[parent] != nil, "\(id) lists without its parent \(parent): \(work)") } }
        #expect(work["itm_mc"] != nil, "Work's group with a workspace here lists in Work: \(work)")
        #expect(work["itm_mk"] == nil, "a Work group under Default's group leaves with it: \(work)")

        let home = Self.machineGroupRows(room: Self.home)
        for (id, parent) in home { if let parent { #expect(home[parent] != nil, "\(id) lists without its parent \(parent): \(home)") } }
        #expect(home["itm_mo"] != nil && home["itm_mk"] == nil && home["itm_me"] == nil, "\(home)")
    }

    /// Only a Pinned link, tab or app belongs to a space. A built-in, a room or a saved group stays shared: pinning
    /// or moving one into Pinned in Work stores no space, and one stored in Pinned draws in every space.
    @Test func onlyLinksTabsAndAppsBelongToASpace() throws {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        store.newItemRoom = { Self.work }
        let layout = SidebarLayoutDocument.defaults
        let shared: [LayoutItemRef] = [.builtIn(.settings), LayoutItemRef(kind: LayoutItemRef.roomKind, value: "room-1"),
                                       LayoutItemRef(kind: LayoutItemRef.savedGroupKind, value: "saved-1")]
        for (index, ref) in shared.enumerated() {
            let item = LayoutItem(id: LayoutItemID("itm_s\(index)"), ref: ref)
            let pin = try #require(layout.pinOp(ref, newItem: item.id), "\(ref)")
            let add = try #require(try store.docOps(for: [pin], layout: layout).first { $0["op"] as? String == "item.add" })
            #expect((add["item"] as? [String: Any])?["extra"] == nil, "\(ref) stored a space: \(add)")
        }
        let app = LayoutItem(id: LayoutItemID("itm_app"), ref: LayoutItemRef(kind: LayoutItemRef.appKind, value: "acme.weather"))
        let appPin = try #require(layout.pinOp(app.ref, newItem: app.id))
        let appAdd = try #require(try store.docOps(for: [appPin], layout: layout).first { $0["op"] as? String == "item.add" })
        #expect(((appAdd["item"] as? [String: Any])?["extra"] as? [String: String])?["room"] == Self.work, "\(appAdd)")

        let records = SidebarDocRecords(sections: [
            Self.pinned: SidebarDocSection(id: Self.pinned, kind: .pinned, region: .top),
            Self.custom: SidebarDocSection(id: Self.custom, kind: .custom, title: "Work"),
        ], items: [
            "itm_b": SidebarDocItem(id: "itm_b", section: Self.custom, body: .builtin("settings")),
            "itm_r": SidebarDocItem(id: "itm_r", section: Self.custom, body: .room("room-1")),
            "itm_t": SidebarDocItem(id: "itm_t", section: Self.custom, body: .tab("tab-1")),
        ])
        let stamped = SidebarDocStore.roomOps(moving: ["itm_b", "itm_r", "itm_t"], into: Self.pinned, room: Self.work, records: records)
        #expect(stamped.compactMap { $0["id"] as? String } == ["itm_t"], "\(stamped)")

        let pinnedRecords = SidebarDocRecords(sections: [
            Self.pinned: SidebarDocSection(id: Self.pinned, kind: .pinned, region: .top),
        ], items: [
            "itm_pb": SidebarDocItem(id: "itm_pb", section: Self.pinned, body: .builtin("settings")),
            "itm_pl": SidebarDocItem(id: "itm_pl", section: Self.pinned, body: .url("https://old.example", title: nil)),
        ])
        let rows = [
            SidebarDocRow(key: "itm_pb", kind: "built_in", section: Self.pinned, item: "itm_pb"),
            SidebarDocRow(key: "itm_pl", kind: "url", section: Self.pinned, item: "itm_pl"),
        ]
        let projection = SidebarDocProjection(rows: rows, records: pinnedRecords, revision: 1)
        let inWork = projection.layout.scopedToWindow(ownedElsewhere: { _ in false }, room: Self.work)
        #expect(inWork.section(SidebarLayoutDocument.pinnedSectionID)?.items.map(\.id.rawValue) == ["itm_pb"],
                "a pinned built-in draws in every space; an old link is Default's")
    }
}
