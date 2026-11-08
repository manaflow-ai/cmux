@testable import CmuxNextSidebar
import Testing

/// An app section the daemon places in the scrolling area (`defaultRegion: "middle"`) is appended
/// after the machine lists. `arrange` kept a section there only when it had group rows, so the app
/// section (it has none: its content is the app's view) drew nowhere, and a customize section with
/// `"defaultRegion": "middle"` never showed.
@MainActor @Suite struct SidebarDocAppSectionAfterListTests {
    static let session = "s-local"
    static let machine = "sec_m_s-local"
    static let app = "sec_app_threads"
    static let emptyCustom = "sec_empty"

    static func ref(_ id: String) -> SidebarDocWorkspaceRef { SidebarDocWorkspaceRef(sessionID: session, workspaceID: id) }

    static func projection() -> SidebarDocProjection {
        let records = SidebarDocRecords(sections: [
            machine: SidebarDocSection(id: machine, kind: .machine(session: session)),
            // The daemon places an app section with its title shown (`Section::new`), so it lists a header row.
            app: SidebarDocSection(id: app, kind: .app(contribution: "local/customize#cmux.section/1"), showsTitle: true),
            emptyCustom: SidebarDocSection(id: emptyCustom, kind: .custom, title: "Later"),
        ], items: [
            "itm_1": SidebarDocItem(id: "itm_1", section: machine, body: .workspace(ref("ws-1"))),
        ])
        let rows = [
            SidebarDocRow(key: "itm_1", kind: "item", section: machine, item: "itm_1", ref: ref("ws-1")),
            SidebarDocRow(key: app, kind: "section", section: app),
        ]
        return SidebarDocProjection(rows: rows, records: records, revision: 1)
    }

    static let drag = SidebarDocDrag(item: { key in
        if case let .workspace(id) = key { return "itm_" + id.rawValue.dropFirst(3) }
        return nil
    }, section: { id in id == .machine(.local) ? machine : nil }, begin: { _ in [:] }, drop: { _, _ in })

    static func raw() -> [SidebarSection] {
        [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(SidebarWorkspace(id: WorkspaceID("ws-1"), title: "ws-1")),
        ])]
    }

    @Test func anAppSectionAfterTheMachineListsIsListed() {
        let projection = Self.projection()
        #expect(projection.layout.sections.map(\.id.rawValue).last == Self.app, "fixture: the app section comes after the list")
        let arranged = projection.arrange(Self.raw(), drag: Self.drag)
        let ids = arranged.map(\.id)
        #expect(ids.last == .custom(Self.app), "the app section draws after the machine list: \(ids)")
        #expect(!ids.contains(.custom(Self.emptyCustom)), "an empty item section after the list still draws nothing: \(ids)")
    }
}
