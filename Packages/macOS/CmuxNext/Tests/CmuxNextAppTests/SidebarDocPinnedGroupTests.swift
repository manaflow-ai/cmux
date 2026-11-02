import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Testing

/// Pinned groups on the sidebar document (Lawrence 2026-10-20: "I made it move to the top but it's
/// still behind the groups … maybe it's because some groups are pinned, but then I also need to
/// have the concept of pinned groups"; plans/cmux-next/sidebar-ordering-DESIGN.md).
///
/// Pin Group moves a group into the Pinned band, which lists above every machine section, so
/// Move to Top leaves a workspace under it by design. The group mapped with `pinned: false`, so
/// its header drew no pin, the menu could not say Unpin, and Pin/Unpin always sent Pin: the
/// group could never leave the band. A group in Pinned maps as pinned; one in a machine section
/// does not.
@MainActor @Suite struct SidebarDocPinnedGroupTests {
    static let session = "s-local"
    static let machine = "sec_m_s-local"
    static let pinned = "sec_pinned"

    static func ref(_ id: String) -> SidebarDocWorkspaceRef { SidebarDocWorkspaceRef(sessionID: session, workspaceID: id) }

    /// Pinned band: group `gp` (member `ws-0`). Machine section: loose `ws-1`, group `gm` (member `ws-2`).
    static func projection() -> SidebarDocProjection {
        let records = SidebarDocRecords(sections: [
            pinned: SidebarDocSection(id: pinned, kind: .pinned, region: .top),
            machine: SidebarDocSection(id: machine, kind: .machine(session: session)),
        ], items: [
            "itm_gp": SidebarDocItem(id: "itm_gp", section: pinned, body: .group(name: "Pinned one", color: nil, icon: nil, collapsed: false)),
            "itm_0": SidebarDocItem(id: "itm_0", section: pinned, parent: "itm_gp", body: .workspace(ref("ws-0"))),
            "itm_1": SidebarDocItem(id: "itm_1", section: machine, body: .workspace(ref("ws-1"))),
            "itm_gm": SidebarDocItem(id: "itm_gm", section: machine, body: .group(name: "Loose one", color: nil, icon: nil, collapsed: false)),
            "itm_2": SidebarDocItem(id: "itm_2", section: machine, parent: "itm_gm", body: .workspace(ref("ws-2"))),
        ])
        let rows = [
            SidebarDocRow(key: "itm_gp", kind: "group", section: pinned, item: "itm_gp"),
            SidebarDocRow(key: "itm_0", kind: "item", section: pinned, parent: "itm_gp", depth: 1, item: "itm_0", ref: ref("ws-0")),
            SidebarDocRow(key: "itm_1", kind: "item", section: machine, item: "itm_1", ref: ref("ws-1")),
            SidebarDocRow(key: "itm_gm", kind: "group", section: machine, item: "itm_gm"),
            SidebarDocRow(key: "itm_2", kind: "item", section: machine, parent: "itm_gm", depth: 1, item: "itm_2", ref: ref("ws-2")),
        ]
        return SidebarDocProjection(rows: rows, records: records, revision: 1)
    }

    @Test func thePinnedGroupMapsPinnedSoItsHeaderAndMenuCanUnpinIt() throws {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: (0..<3).map { index in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: nil, resourceID: ResourceID(rawValue: "ws-\(index)"), name: "w\(index)")
        }))
        let sections = SidebarDocSections(document: { nil }).sections(Self.projection(), session: Self.session, workspaces: store.workspaces)
        let groups = sections.compactMap(\.group)
        #expect(groups.first { $0.id.rawValue == "itm_gp" }?.pinned == true, "the Pinned group maps unpinned: Pin/Unpin can only pin it")
        #expect(groups.first { $0.id.rawValue == "itm_gm" }?.pinned == false)
    }
}
