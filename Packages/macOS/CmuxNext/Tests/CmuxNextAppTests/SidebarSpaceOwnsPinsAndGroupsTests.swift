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
}
