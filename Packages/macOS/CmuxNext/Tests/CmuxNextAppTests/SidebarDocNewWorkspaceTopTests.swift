@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextSettings
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Testing

/// Cmd-N's workspace is first in the sidebar from its first frame (Lawrence 2026-10-20: "doing
/// Command-N to make a new workspace does not make it the top … Always make it at the top with a
/// single state change, a single render, and have zero jank"; plans/cmux-next/sidebar-ordering-DESIGN.md).
///
/// The app hears of a new workspace twice: `workspace-added` on the event stream, and its sidebar
/// document item on `session.events`. Between the two the workspace is live but not placed by the
/// document, and the sidebar listed such a row after every placed row: the new row jumped in at the
/// bottom, then moved to the top when its item came. It now lists where the daemon places it
/// (`workspaces.newPlacement`, default top: first in its machine section, below Home, above groups
/// and unread rows), so the item's arrival changes nothing on screen.
@MainActor @Suite struct SidebarDocNewWorkspaceTopTests {
    static let session = "s-local"
    static let machine = "sec_m_s-local"

    static func ref(_ id: String) -> SidebarDocWorkspaceRef { SidebarDocWorkspaceRef(sessionID: session, workspaceID: id) }

    /// Machine section: Home, loose `ws-1` (unread), group `g` (member `ws-2`), loose `ws-3`.
    static func projection() -> SidebarDocProjection {
        let records = SidebarDocRecords(sections: [
            machine: SidebarDocSection(id: machine, kind: .machine(session: session)),
        ], items: [
            "itm_h": SidebarDocItem(id: "itm_h", section: machine, body: .workspace(ref("ws-home"))),
            "itm_1": SidebarDocItem(id: "itm_1", section: machine, body: .workspace(ref("ws-1"))),
            "itm_g": SidebarDocItem(id: "itm_g", section: machine, body: .group(name: "Work", color: nil, icon: nil, collapsed: false)),
            "itm_2": SidebarDocItem(id: "itm_2", section: machine, parent: "itm_g", body: .workspace(ref("ws-2"))),
            "itm_3": SidebarDocItem(id: "itm_3", section: machine, body: .workspace(ref("ws-3"))),
        ])
        let rows = [
            SidebarDocRow(key: "itm_h", kind: "item", section: machine, item: "itm_h", ref: ref("ws-home")),
            SidebarDocRow(key: "itm_1", kind: "item", section: machine, item: "itm_1", ref: ref("ws-1")),
            SidebarDocRow(key: "itm_g", kind: "group", section: machine, item: "itm_g"),
            SidebarDocRow(key: "itm_2", kind: "item", section: machine, parent: "itm_g", depth: 1, item: "itm_2", ref: ref("ws-2")),
            SidebarDocRow(key: "itm_3", kind: "item", section: machine, item: "itm_3", ref: ref("ws-3")),
        ]
        return SidebarDocProjection(rows: rows, records: records, revision: 1)
    }

    /// The store: the placed workspaces, then `fresh` (live, no document item yet), in daemon order (a new one last).
    static func store(fresh: [String]) -> DaemonStore {
        let store = DaemonStore()
        let ids = ["ws-home", "ws-1", "ws-2", "ws-3"] + fresh
        store.apply(snapshot: DaemonTree(workspaces: ids.enumerated().map { index, id in
            var snapshot = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: nil, resourceID: ResourceID(rawValue: id),
                                             name: id, markedUnread: id == "ws-1")
            if id == "ws-home" { snapshot.kind = SidebarMapping.homeKind }
            return snapshot
        }))
        return store
    }

    static func order(_ sections: [CmuxNextDaemon.SidebarSection]) -> [String] {
        sections.flatMap(\.workspaces).compactMap(\.resourceID?.rawValue)
    }

    /// `afterCurrent` while the document places none of the rows yet (a fresh session): the current workspace is
    /// itself unplaced, so the new row lists right after it once the unplaced rows are listed, not first or last
    /// (CmdNRowSlotTests drew it first for a frame, then at its slot).
    @Test(arguments: [false, true]) func aNewRowFindsAnUnplacedNeighbour(newRowsFirst: Bool) throws {
        let empty = SidebarDocProjection(rows: [], records: SidebarDocRecords(sections: [
            Self.machine: SidebarDocSection(id: Self.machine, kind: .machine(session: Self.session)),
        ], items: [:]), revision: 1)
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ["ws-1", "ws-2", "ws-3", "ws-new"].enumerated().map { index, id in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: nil, resourceID: ResourceID(rawValue: id), name: id)
        }))
        let current = try #require(store.workspaces.first { $0.resourceID?.rawValue == "ws-2" }).id
        let doc = SidebarDocSections()
        doc.placesNewRowsFirst = { newRowsFirst }
        doc.unplacedAnchor = { $0.resourceID?.rawValue == "ws-new" ? .after(current) : nil }
        let order = Self.order(doc.sections(empty, session: Self.session, workspaces: store.workspaces))
        #expect(order == (newRowsFirst ? ["ws-3", "ws-2", "ws-new", "ws-1"] : ["ws-1", "ws-2", "ws-new", "ws-3"]))
    }

    /// `afterCurrent` with Cmd-N from Home (no current workspace): the daemon puts the new one first below Home,
    /// so its row lists there from the press, not last (and then first); the next Cmd-N lists right after it.
    @Test func aNewRowWithNoCurrentWorkspaceListsFirstUnderAfterCurrent() throws {
        let store = Self.store(fresh: ["ws-a", "ws-b"])
        let a = try #require(store.workspaces.first { $0.resourceID?.rawValue == "ws-a" }).id
        let doc = SidebarDocSections()
        doc.placesNewRowsFirst = { false }
        doc.unplacedAnchor = { $0.resourceID?.rawValue == "ws-a" ? .first : $0.resourceID?.rawValue == "ws-b" ? .after(a) : nil }
        #expect(Self.order(doc.sections(Self.projection(), session: Self.session, workspaces: store.workspaces))
            == ["ws-home", "ws-a", "ws-b", "ws-1", "ws-2", "ws-3"])
    }

    /// The same before the document places any row (a fresh session): first below Home, not above it.
    @Test func aNewRowWithNoCurrentWorkspaceListsBelowAnUnplacedHome() {
        let empty = SidebarDocProjection(rows: [], records: SidebarDocRecords(sections: [
            Self.machine: SidebarDocSection(id: Self.machine, kind: .machine(session: Self.session)),
        ], items: [:]), revision: 1)
        let doc = SidebarDocSections()
        doc.placesNewRowsFirst = { false }
        doc.unplacedAnchor = { $0.resourceID?.rawValue == "ws-a" ? .first : nil }
        #expect(Self.order(doc.sections(empty, session: Self.session, workspaces: Self.store(fresh: ["ws-a"]).workspaces))
            == ["ws-home", "ws-a", "ws-1", "ws-2", "ws-3"])
    }

    @Test(arguments: [NewWorkspacePlacement.beforeCurrent, .afterCurrent])
    func aMissingCurrentWorkspaceFallsBackToTopFromItsFirstFrame(placement: NewWorkspacePlacement) {
        let doc = SidebarDocSections()
        doc.placesNewRowsFirst = { false }
        let anchor = NewWorkspacePlacements.anchor(slot: nil, byDefault: .init(placement: placement, current: "not-in-this-machine"), home: nil)
        doc.unplacedAnchor = { $0.resourceID?.rawValue == "ws-new" ? anchor : nil }
        #expect(Self.order(doc.sections(Self.projection(), session: Self.session, workspaces: Self.store(fresh: ["ws-new"]).workspaces))
            == ["ws-home", "ws-new", "ws-1", "ws-2", "ws-3"])
    }

    @Test func aLiveWorkspaceTheDocumentDoesNotPlaceYetListsFirstBelowHome() {
        let store = Self.store(fresh: ["ws-new"])
        let sections = SidebarDocSections().sections(Self.projection(), session: Self.session, workspaces: store.workspaces)
        #expect(Self.order(sections) == ["ws-home", "ws-new", "ws-1", "ws-2", "ws-3"],
                "the new row is not first: it jumps from here to the top when its item comes")
        // Loose above every group: the new row is in the first loose section, not a group.
        #expect(sections.first?.group == nil && sections.first?.workspaces.compactMap(\.resourceID?.rawValue).contains("ws-new") == true)
    }

    /// Rapid Cmd-N: several live workspaces without items (and without personal rows, which come
    /// with the items) list at the top in the order the daemon will place them, newest first, each
    /// above the rows that were there. The store lists them in creation order.
    @Test func rapidCreatesListNewestFirstAtTheTop() {
        let store = Self.store(fresh: ["ws-a", "ws-b", "ws-c"])
        let sections = SidebarDocSections().sections(Self.projection(), session: Self.session, workspaces: store.workspaces)
        #expect(Self.order(sections) == ["ws-home", "ws-c", "ws-b", "ws-a", "ws-1", "ws-2", "ws-3"])
    }

    static func groupProjection() -> SidebarDocProjection {
        let records = SidebarDocRecords(sections: [
            Self.machine: SidebarDocSection(id: Self.machine, kind: .machine(session: Self.session)),
        ], items: [
            "itm_g": SidebarDocItem(id: "itm_g", section: Self.machine, body: .group(name: "Work", color: nil, icon: nil, collapsed: false)),
            "itm_2": SidebarDocItem(id: "itm_2", section: Self.machine, parent: "itm_g", body: .workspace(Self.ref("ws-2"))),
        ])
        let rows = [
            SidebarDocRow(key: "itm_g", kind: "group", section: Self.machine, item: "itm_g"),
            SidebarDocRow(key: "itm_2", kind: "item", section: Self.machine, parent: "itm_g", depth: 1, item: "itm_2", ref: Self.ref("ws-2")),
        ]
        return SidebarDocProjection(rows: rows, records: records, revision: 1)
    }

    /// With the machine section starting on a group (no Home row), the new row still lists first,
    /// as its own loose run above the group.
    @Test func aSectionThatStartsWithAGroupGetsTheNewRowAboveIt() {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ["ws-2", "ws-new"].enumerated().map { index, id in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: nil, resourceID: ResourceID(rawValue: id), name: id)
        }))
        let sections = SidebarDocSections().sections(Self.groupProjection(), session: Self.session, workspaces: store.workspaces)
        #expect(Self.order(sections) == ["ws-new", "ws-2"])
        #expect(sections.first?.group == nil)
    }
    @Test func aMissingAnchorKeepsTheTrailingRunAndGroupIntact() throws {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ["ws-2", "ws-a", "ws-d", "ws-e"].enumerated().map { index, id in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: nil, resourceID: ResourceID(rawValue: id), name: id)
        }))
        let a = try #require(store.workspaces.first { $0.resourceID?.rawValue == "ws-a" }).id
        let doc = SidebarDocSections()
        doc.placesNewRowsFirst = { false }
        doc.unplacedAnchor = { workspace in
            switch workspace.resourceID?.rawValue {
            case "ws-d": .after("missing", fallbackFirst: true)
            case "ws-e": .after(a)
            default: nil
            }
        }
        let sections = doc.sections(Self.groupProjection(), session: Self.session, workspaces: store.workspaces)
        #expect(Self.order(sections) == ["ws-d", "ws-2", "ws-a", "ws-e"])
        #expect(sections.filter { $0.group != nil }.count == 1)
    }

}
