@testable import CmuxNextSidebar
import Testing

/// `SidebarDocProjection.arrange` places the bridge's sections as the sidebar document orders them. Run on
/// sections it already arranged (#23684: a section fold passed the shown list back in), it inserted the
/// document's sections above and below the machine lists a second time, and a machine list's link rows
/// came twice: the list dropped by those sections' height under an empty band. Arranging is idempotent:
/// arranging an arranged list changes nothing, so no caller can repeat that.
@MainActor @Suite struct SidebarDocArrangeIdempotenceTests {
    static let session = "s-local"
    static let machine = "sec_m_s-local"
    static let pinned = "sec_pinned"
    static let after = "sec_after"

    static func ref(_ id: String) -> SidebarDocWorkspaceRef { SidebarDocWorkspaceRef(sessionID: session, workspaceID: id) }

    /// Pinned band (group `gp`, member `ws-0`) above This Mac; This Mac: `ws-1`, a link, group `gm`
    /// (member `ws-2`); a section after the machine lists with group `ga` (member `ws-3`).
    static func projection() -> SidebarDocProjection {
        let records = SidebarDocRecords(sections: [
            pinned: SidebarDocSection(id: pinned, kind: .pinned, region: .top),
            machine: SidebarDocSection(id: machine, kind: .machine(session: session)),
            after: SidebarDocSection(id: after, kind: .custom, title: "Later"),
        ], items: [
            "itm_gp": SidebarDocItem(id: "itm_gp", section: pinned, body: .group(name: "Pinned one", color: nil, icon: nil, collapsed: false)),
            "itm_0": SidebarDocItem(id: "itm_0", section: pinned, parent: "itm_gp", body: .workspace(ref("ws-0"))),
            "itm_1": SidebarDocItem(id: "itm_1", section: machine, body: .workspace(ref("ws-1"))),
            "itm_link": SidebarDocItem(id: "itm_link", section: machine, body: .url("https://example.com/docs", title: "Docs")),
            "itm_gm": SidebarDocItem(id: "itm_gm", section: machine, body: .group(name: "Loose one", color: nil, icon: nil, collapsed: false)),
            "itm_2": SidebarDocItem(id: "itm_2", section: machine, parent: "itm_gm", body: .workspace(ref("ws-2"))),
            "itm_ga": SidebarDocItem(id: "itm_ga", section: after, body: .group(name: "Later one", color: nil, icon: nil, collapsed: false)),
            "itm_3": SidebarDocItem(id: "itm_3", section: after, parent: "itm_ga", body: .workspace(ref("ws-3"))),
        ])
        let rows = [
            SidebarDocRow(key: "itm_gp", kind: "group", section: pinned, item: "itm_gp"),
            SidebarDocRow(key: "itm_0", kind: "item", section: pinned, parent: "itm_gp", depth: 1, item: "itm_0", ref: ref("ws-0")),
            SidebarDocRow(key: "itm_1", kind: "item", section: machine, item: "itm_1", ref: ref("ws-1")),
            SidebarDocRow(key: "itm_link", kind: "item", section: machine, item: "itm_link"),
            SidebarDocRow(key: "itm_gm", kind: "group", section: machine, item: "itm_gm"),
            SidebarDocRow(key: "itm_2", kind: "item", section: machine, parent: "itm_gm", depth: 1, item: "itm_2", ref: ref("ws-2")),
            SidebarDocRow(key: "itm_ga", kind: "group", section: after, item: "itm_ga"),
            SidebarDocRow(key: "itm_3", kind: "item", section: after, parent: "itm_ga", depth: 1, item: "itm_3", ref: ref("ws-3")),
        ]
        return SidebarDocProjection(rows: rows, records: records, revision: 1)
    }

    static func ws(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    static func group(_ id: String, _ member: String) -> SidebarNode {
        .group(SidebarGroup(id: GroupID(id), name: id, workspaces: [ws(member)]))
    }

    /// The bridge's mapping: every group in This Mac's section, as the app maps daemon state.
    static func raw() -> [SidebarSection] {
        [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(ws("ws-1")), group("itm_gp", "ws-0"), group("itm_gm", "ws-2"), group("itm_ga", "ws-3"),
        ])]
    }

    static let drag = SidebarDocDrag(item: { key in
        if case let .workspace(id) = key { return "itm_" + id.rawValue.dropFirst(3) }
        return nil
    }, section: { id in id == .machine(.local) ? machine : nil }, begin: { _ in [:] }, drop: { _, _ in })

    static func describe(_ sections: [SidebarSection]) -> [String] {
        sections.map { section in "\(section.id): " + section.nodes.map { "\($0.id)" }.joined(separator: ", ") }
    }

    @Test func arrangingAnArrangedListChangesNothing() {
        let projection = Self.projection()
        let once = projection.arrange(Self.raw(), drag: Self.drag)
        // The fixture reaches every part `arrange` builds: a section before the machine lists, one after,
        // and a link row in This Mac's list.
        #expect(once.contains { $0.id == .custom(Self.pinned) }, "no Pinned section: \(Self.describe(once))")
        #expect(once.contains { $0.id == .custom(Self.after) }, "no section after the machine lists: \(Self.describe(once))")
        #expect(once.flatMap(\.nodes).contains { if case .item = $0 { true } else { false } }, "no link row: \(Self.describe(once))")
        let twice = projection.arrange(once, drag: Self.drag)
        #expect(Self.describe(twice) == Self.describe(once))
        #expect(twice == once)
        #expect(projection.arrange(twice, drag: Self.drag) == once)
    }

    @Test func anArrangedListKeysEverySectionAndRowOnce() {
        let projection = Self.projection()
        let twice = projection.arrange(projection.arrange(Self.raw(), drag: Self.drag), drag: Self.drag)
        let sections = twice.map(\.id)
        #expect(Set(sections).count == sections.count, "a section comes twice: \(Self.describe(twice))")
        let rows = twice.flatMap(\.nodes).map(\.id)
        #expect(Set(rows).count == rows.count, "a row comes twice: \(Self.describe(twice))")
    }
}
