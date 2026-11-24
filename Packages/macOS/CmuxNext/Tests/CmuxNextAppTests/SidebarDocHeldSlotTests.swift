import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-07: "this is also just insanely weird sidebar group behaviour. see i selected you and then i collapse
/// the group you're in then i click elsewhere and then all sorts of wack nonsense occurs". Running members of a
/// collapsed group the document stopped placing for a moment (their item or ref in flight) listed as new rows, right
/// below the current workspace: a click elsewhere moved them out of the group and under the clicked row, and the
/// group, opened again, listed without them until the document placed them back. A row that listed keeps its slot
/// (its group, under the same row); a new row keeps the place it first took, whatever is selected after.
@MainActor @Suite struct SidebarDocHeldSlotTests {
    static let session = "s-local"
    static let machine = "sec_m_s-local"

    static func ref(_ id: String) -> SidebarDocWorkspaceRef { SidebarDocWorkspaceRef(sessionID: session, workspaceID: id) }

    /// Machine section: loose `ws-1`, group `g` (members `members` in order), loose `ws-3`, the loose `after3`, `ws-4`.
    static func projection(members: [String], after3: [String] = [], dropping: Set<String> = []) -> SidebarDocProjection {
        var items: [String: SidebarDocItem] = [
            "itm_1": SidebarDocItem(id: "itm_1", section: machine, body: .workspace(ref("ws-1"))),
            "itm_g": SidebarDocItem(id: "itm_g", section: machine, body: .group(name: "Leads", color: nil, icon: nil, collapsed: true)),
            "itm_3": SidebarDocItem(id: "itm_3", section: machine, body: .workspace(ref("ws-3"))),
            "itm_4": SidebarDocItem(id: "itm_4", section: machine, body: .workspace(ref("ws-4"))),
        ]
        var rows = [
            SidebarDocRow(key: "itm_1", kind: "item", section: machine, item: "itm_1", ref: ref("ws-1")),
            SidebarDocRow(key: "itm_g", kind: "group", section: machine, item: "itm_g"),
        ]
        for member in members {
            items["itm_" + member] = SidebarDocItem(id: "itm_" + member, section: machine, parent: "itm_g", body: .workspace(ref(member)))
            rows.append(SidebarDocRow(key: "itm_" + member, kind: "item", section: machine, parent: "itm_g", depth: 1, item: "itm_" + member, ref: ref(member)))
        }
        rows.append(SidebarDocRow(key: "itm_3", kind: "item", section: machine, item: "itm_3", ref: ref("ws-3")))
        for id in after3 {
            items["itm_" + id] = SidebarDocItem(id: "itm_" + id, section: machine, body: .workspace(ref(id)))
            rows.append(SidebarDocRow(key: "itm_" + id, kind: "item", section: machine, item: "itm_" + id, ref: ref(id)))
        }
        rows.append(SidebarDocRow(key: "itm_4", kind: "item", section: machine, item: "itm_4", ref: ref("ws-4")))
        rows.removeAll { $0.ref.map { dropping.contains($0.workspaceID) } ?? false }
        for id in dropping { items["itm_" + String(id.dropFirst(3))] = nil }
        let records = SidebarDocRecords(sections: [machine: SidebarDocSection(id: machine, kind: .machine(session: session))], items: items)
        return SidebarDocProjection(rows: rows, records: records, revision: 1)
    }

    static let members = ["ws-coord", "ws-merge", "ws-adopt-a", "ws-adopt-b", "ws-411"]

    static func store(_ ids: [String]) -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.enumerated().map { index, id in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: nil, resourceID: ResourceID(rawValue: id), name: id)
        }))
        return store
    }

    /// The store's id of document workspace `resource` (what the window's current workspace names).
    static func id(_ resource: String, in store: DaemonStore) -> String {
        store.workspaces.first { $0.resourceID?.rawValue == resource }?.id ?? resource
    }

    static func layout(_ sections: [CmuxNextDaemon.SidebarSection]) -> [String] {
        sections.map { section in
            let rows = section.workspaces.compactMap(\.resourceID?.rawValue).joined(separator: ",")
            return section.group.map { "[\($0.name): \(rows)]" } ?? rows
        }
    }

    /// The group lists its five members; then the document stops placing the three running ones while the selection
    /// moves to a loose row below the group: they stay in the group, in their order, on every pass.
    @Test func aMemberTheDocumentStopsPlacingKeepsItsSlot() {
        let store = Self.store(["ws-1"] + Self.members + ["ws-3", "ws-4"])
        let docSections = SidebarDocSections(document: { nil })
        docSections.newRowsPlace = { .below(Self.id("ws-coord", in: store)) }
        let before = Self.layout(docSections.sections(Self.projection(members: Self.members), session: Self.session, workspaces: store.workspaces))
        let placing = Self.members.filter { !["ws-merge", "ws-adopt-a", "ws-adopt-b"].contains($0) }
        for current in ["ws-3", "ws-4", "ws-1"] {
            docSections.newRowsPlace = { .below(Self.id(current, in: store)) }
            let during = Self.layout(docSections.sections(Self.projection(members: placing), session: Self.session, workspaces: store.workspaces))
            #expect(during == before, "with \(current) selected the rows list as \(during), not \(before)")
        }
        let after = Self.layout(docSections.sections(Self.projection(members: Self.members), session: Self.session, workspaces: store.workspaces))
        #expect(after == before, "placed again, the rows list as \(after), not \(before)")
    }

    /// A new row (no item yet) lists below the workspace current when it came; a click elsewhere does not move it.
    @Test func aNewRowKeepsThePlaceItFirstTook() {
        let store = Self.store(["ws-1"] + Self.members + ["ws-3", "ws-4", "ws-new"])
        let docSections = SidebarDocSections(document: { nil })
        docSections.newRowsPlace = { .below(Self.id("ws-3", in: store)) }
        let first = Self.layout(docSections.sections(Self.projection(members: Self.members), session: Self.session, workspaces: store.workspaces))
        #expect(first.last == "ws-3,ws-new,ws-4", "the new row is not below ws-3: \(first)")
        docSections.newRowsPlace = { .below(Self.id("ws-1", in: store)) }
        let clicked = Self.layout(docSections.sections(Self.projection(members: Self.members), session: Self.session, workspaces: store.workspaces))
        #expect(clicked == first, "a click on ws-1 moved the new row: \(clicked), was \(first)")
    }

    /// A new row (no slot yet) lists while a member the document stopped placing goes back in its slot.
    @Test func aNewRowListsWhileAMemberIsHeld() {
        let store = Self.store(["ws-1"] + Self.members + ["ws-3", "ws-4"])
        let docSections = SidebarDocSections(document: { nil })
        docSections.newRowsPlace = { .below(Self.id("ws-3", in: store)) }
        let before = Self.layout(docSections.sections(Self.projection(members: Self.members), session: Self.session, workspaces: store.workspaces))
        let grown = Self.store(["ws-1"] + Self.members + ["ws-3", "ws-4", "ws-new"])
        let placing = Self.members.filter { $0 != "ws-merge" }
        let during = Self.layout(docSections.sections(Self.projection(members: placing), session: Self.session, workspaces: grown.workspaces))
        #expect(during.dropLast() == before.dropLast(), "the held member left its group: \(during), was \(before)")
        #expect(during.last == "ws-3,ws-new,ws-4", "the new row does not list below ws-3: \(during)")
    }

    /// Rapid Cmd-N below ws-3 (each new row selected): when the first one's item arrives before the second's, the
    /// second stays under it, never jumping above it until its own item comes.
    @Test func aChainOfCreatesKeepsItsOrderAsItemsArriveOneByOne() {
        let store = Self.store(["ws-1"] + Self.members + ["ws-3", "ws-4", "ws-a", "ws-b"])
        let docSections = SidebarDocSections(document: { nil })
        let full = Self.projection(members: Self.members)
        let without = { (ids: Set<String>) in store.workspaces.filter { !ids.contains($0.resourceID?.rawValue ?? "") } }
        docSections.newRowsPlace = { .below(Self.id("ws-3", in: store)) }
        _ = docSections.sections(full, session: Self.session, workspaces: without(["ws-a", "ws-b"]))
        docSections.newRowsPlace = { .below(Self.id("ws-a", in: store)) }
        _ = docSections.sections(full, session: Self.session, workspaces: without(["ws-b"]))
        docSections.newRowsPlace = { .below(Self.id("ws-b", in: store)) }
        let both = Self.layout(docSections.sections(full, session: Self.session, workspaces: store.workspaces))
        #expect(both.last == "ws-3,ws-a,ws-b,ws-4", "both new rows: \(both)")
        let aPlaced = Self.layout(docSections.sections(Self.projection(members: Self.members, after3: ["ws-a"]), session: Self.session,
                                                       workspaces: store.workspaces))
        #expect(aPlaced.last == "ws-3,ws-a,ws-b,ws-4", "ws-a's item came first: \(aPlaced)")
    }

    /// Two creates below a group member (the second below the first), then the member selected again: both stay in
    /// the group, in press order, whatever order the pass lists new rows in.
    @Test func aChainOfCreatesInAGroupStaysInItWhenAMemberIsSelected() {
        let store = Self.store(["ws-1"] + Self.members + ["ws-3", "ws-4", "ws-a", "ws-b"])
        let docSections = SidebarDocSections(document: { nil })
        let full = Self.projection(members: Self.members)
        let without = { (ids: Set<String>) in store.workspaces.filter { !ids.contains($0.resourceID?.rawValue ?? "") } }
        docSections.newRowsPlace = { .below(Self.id("ws-coord", in: store)) }
        _ = docSections.sections(full, session: Self.session, workspaces: without(["ws-a", "ws-b"]))
        docSections.newRowsPlace = { .below(Self.id("ws-a", in: store)) }
        _ = docSections.sections(full, session: Self.session, workspaces: without(["ws-b"]))
        docSections.newRowsPlace = { .below(Self.id("ws-b", in: store)) }
        _ = docSections.sections(full, session: Self.session, workspaces: store.workspaces)
        docSections.newRowsPlace = { .below(Self.id("ws-coord", in: store)) }
        let selected = Self.layout(docSections.sections(full, session: Self.session, workspaces: store.workspaces))
        #expect(selected.contains("[Leads: ws-coord,ws-a,ws-b,ws-merge,ws-adopt-a,ws-adopt-b,ws-411]"), "the new rows left Leads: \(selected)")
    }

    /// A machine that is only a group: a new row listed first opens a loose section above it, and a new row below a
    /// member still goes into the group.
    @Test func aNewRowBelowAMemberJoinsTheGroupWhenAnotherOpensALooseRunAbove() {
        let records = SidebarDocRecords(sections: [Self.machine: SidebarDocSection(id: Self.machine, kind: .machine(session: Self.session))], items: [
            "itm_g": SidebarDocItem(id: "itm_g", section: Self.machine, body: .group(name: "Leads", color: nil, icon: nil, collapsed: false)),
            "itm_a": SidebarDocItem(id: "itm_a", section: Self.machine, parent: "itm_g", body: .workspace(Self.ref("ws-a"))),
            "itm_b": SidebarDocItem(id: "itm_b", section: Self.machine, parent: "itm_g", body: .workspace(Self.ref("ws-b"))),
        ])
        let projection = SidebarDocProjection(rows: [
            SidebarDocRow(key: "itm_g", kind: "group", section: Self.machine, item: "itm_g"),
            SidebarDocRow(key: "itm_a", kind: "item", section: Self.machine, parent: "itm_g", depth: 1, item: "itm_a", ref: Self.ref("ws-a")),
            SidebarDocRow(key: "itm_b", kind: "item", section: Self.machine, parent: "itm_g", depth: 1, item: "itm_b", ref: Self.ref("ws-b")),
        ], records: records, revision: 1)
        let store = Self.store(["ws-a", "ws-b", "ws-x", "ws-y"])
        let docSections = SidebarDocSections(document: { nil })
        docSections.newRowsPlace = { .below("gone") }
        _ = docSections.sections(projection, session: Self.session, workspaces: store.workspaces.filter { $0.resourceID?.rawValue != "ws-y" })
        docSections.newRowsPlace = { .below(Self.id("ws-a", in: store)) }
        let shown = Self.layout(docSections.sections(projection, session: Self.session, workspaces: store.workspaces))
        #expect(shown == ["ws-x", "[Leads: ws-a,ws-y,ws-b]"], "ws-y is not in Leads below ws-a: \(shown)")
    }

    /// The loose run under the group keeps its place when the document stops placing its first row, or all of it:
    /// it never moves into the run above the group.
    @Test(arguments: [["ws-3"], ["ws-3", "ws-4"]]) func aLooseRunUnderTheGroupStaysUnderIt(_ dropped: [String]) {
        let store = Self.store(["ws-1"] + Self.members + ["ws-3", "ws-4"])
        let docSections = SidebarDocSections(document: { nil })
        docSections.newRowsPlace = { .last }
        let before = Self.layout(docSections.sections(Self.projection(members: Self.members), session: Self.session, workspaces: store.workspaces))
        let during = Self.layout(docSections.sections(Self.projection(members: Self.members, dropping: Set(dropped)), session: Self.session,
                                                      workspaces: store.workspaces))
        #expect(during == before, "without \(dropped) the rows list as \(during), not \(before)")
    }
}
