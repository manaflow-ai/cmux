import Foundation
@testable import CmuxNextSidebar
import Testing

/// Archiving sidebar items (plans/cmux-next/archiving-DESIGN.md): the reducer keeps an archived item
/// in its group (or section), last, marks it `extra.archived` and flags its rows (and every row under an
/// archived group) `archived`. The client reads the mark for the Archive/Unarchive titles, and the list
/// draws the flagged workspace, group and link rows dimmed.
@MainActor @Suite struct SidebarDocArchiveTests {
    static let session = "s-local"
    static let machine = "sec_m_s-local"

    static func ref(_ id: String) -> SidebarDocWorkspaceRef { SidebarDocWorkspaceRef(sessionID: session, workspaceID: id) }

    /// This Mac: `ws-1`, group `gm` (member `ws-2`), `ws-3`, a link; the reducer's rows put the archived ones last.
    static func projection(archived: Set<String>) -> SidebarDocProjection {
        let records = SidebarDocRecords(sections: [
            machine: SidebarDocSection(id: machine, kind: .machine(session: session)),
        ], items: [
            "itm_1": SidebarDocItem(id: "itm_1", section: machine, body: .workspace(ref("ws-1")), archived: archived.contains("itm_1")),
            "itm_gm": SidebarDocItem(id: "itm_gm", section: machine, body: .group(name: "G", color: nil, icon: nil, collapsed: false),
                                     archived: archived.contains("itm_gm")),
            "itm_2": SidebarDocItem(id: "itm_2", section: machine, parent: "itm_gm", body: .workspace(ref("ws-2"))),
            "itm_3": SidebarDocItem(id: "itm_3", section: machine, body: .workspace(ref("ws-3"))),
            "itm_link": SidebarDocItem(id: "itm_link", section: machine, body: .url("https://example.com/docs", title: "Docs"),
                                       archived: archived.contains("itm_link")),
        ])
        let dim = { (id: String, under: String?) in archived.contains(id) || under.map { archived.contains($0) } == true }
        let rows = [
            SidebarDocRow(key: "itm_3", kind: "item", section: machine, item: "itm_3", ref: ref("ws-3")),
            SidebarDocRow(key: "itm_1", kind: "item", section: machine, item: "itm_1", archived: dim("itm_1", nil), ref: ref("ws-1")),
            SidebarDocRow(key: "itm_gm", kind: "group", section: machine, item: "itm_gm", archived: dim("itm_gm", nil)),
            SidebarDocRow(key: "itm_2", kind: "item", section: machine, parent: "itm_gm", depth: 1, item: "itm_2",
                          archived: dim("itm_2", "itm_gm"), ref: ref("ws-2")),
            SidebarDocRow(key: "itm_link", kind: "item", section: machine, item: "itm_link", archived: dim("itm_link", nil)),
        ]
        return SidebarDocProjection(rows: rows, records: records, revision: 1)
    }

    static func ws(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    static func raw() -> [SidebarSection] {
        [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(ws("ws-3")), .workspace(ws("ws-1")), .group(SidebarGroup(id: GroupID("itm_gm"), name: "G", workspaces: [ws("ws-2")])),
        ])]
    }

    static let drag = SidebarDocDrag(item: { key in
        if case let .workspace(id) = key { return "itm_" + id.rawValue.dropFirst(3) }
        return nil
    }, section: { id in id == .machine(.local) ? machine : nil }, begin: { _ in [:] }, drop: { _, _ in })

    /// Each drawn row's archived look, by row id.
    static func looks(_ sections: [SidebarSection]) -> [String: Bool] {
        var looks: [String: Bool] = [:]
        for node in sections.flatMap(\.nodes) {
            switch node {
            case .workspace(let workspace): looks[workspace.id.rawValue] = workspace.isArchived
            case .item(let item): looks[item.id] = item.isArchived
            case .group(let group):
                looks[group.id.rawValue] = group.isArchived
                for workspace in group.workspaces { looks[workspace.id.rawValue] = workspace.isArchived }
            }
        }
        return looks
    }

    @Test func theWireMarkReadsArchived() throws {
        let document = Data("""
        {"revision": "3",
         "sections": [{"id": "sec_m_s1", "kind": {"type": "machine", "session_id": "s1"}}],
         "items": [
           {"id": "w1", "section": "sec_m_s1", "order": "a", "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "ws_1"}}},
           {"id": "w2", "section": "sec_m_s1", "order": "b", "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "ws_2"}},
            "extra": {"archived": true, "unarchive_to": {"after": "w1"}}}
         ]}
        """.utf8)
        var records = try SidebarDocRecords(document: document)
        #expect(records.isArchived(item: "w2"), "Archive/Unarchive on an archived row must read Unarchive")
        #expect(!records.isArchived(item: "w1"))
        // Unarchive's echo clears it.
        records.apply(batch: Data("""
        {"changes": [{"kind": "state_upsert", "resource": "sidebar_item", "id": "w2",
          "value": {"id": "w2", "section": "sec_m_s1", "order": "a5",
                    "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "ws_2"}}}}]}
        """.utf8))
        #expect(!records.isArchived(item: "w2"))
    }

    @Test func archivedRowsDrawDimmedAndAGroupDimsItsMembers() {
        let arranged = Self.projection(archived: ["itm_1", "itm_gm", "itm_link"]).arrange(Self.raw(), drag: Self.drag)
        let looks = Self.looks(arranged)
        #expect(looks["ws-1"] == true)
        #expect(looks["itm_gm"] == true)
        #expect(looks["ws-2"] == true, "a member of an archived group draws dimmed with it")
        #expect(looks["itm_link"] == true)
        #expect(looks["ws-3"] == false)
    }

    @Test func unarchiveClearsTheLookOnAnArrangedList() {
        // A fold passes the shown list back in: the old mark must not stay.
        let once = Self.projection(archived: ["itm_1", "itm_gm"]).arrange(Self.raw(), drag: Self.drag)
        let again = Self.projection(archived: []).arrange(once, drag: Self.drag)
        #expect(Self.looks(again).values.allSatisfy { !$0 }, "\(Self.looks(again))")
    }

    @Test func aRowPatchKeepsTheArchivedLook() throws {
        // A title or status tick patches the row in place, with no `arrange`: the mark must stay.
        let model = SidebarModel(sections: Self.projection(archived: ["itm_1"]).arrange(Self.raw(), drag: Self.drag))
        var renamed = Self.ws("ws-1")
        renamed.title = "renamed"
        #expect(model.patchWorkspaces([renamed]))
        #expect(Self.looks(model.sections)["ws-1"] == true)
    }
}
