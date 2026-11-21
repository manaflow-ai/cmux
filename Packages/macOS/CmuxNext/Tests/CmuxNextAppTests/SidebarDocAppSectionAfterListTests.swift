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

    static func projection(withApp: Bool = true) -> SidebarDocProjection {
        var sections: [String: SidebarDocSection] = [
            machine: SidebarDocSection(id: machine, kind: .machine(session: session)),
            // The daemon places an app section with its title shown (`Section::new`), so it lists a header row.
            app: SidebarDocSection(id: app, kind: .app(contribution: "local/customize#cmux.section/1"), showsTitle: true),
            emptyCustom: SidebarDocSection(id: emptyCustom, kind: .custom, title: "Later"),
        ]
        if !withApp { sections[app] = nil }
        let records = SidebarDocRecords(sections: sections, items: [
            "itm_1": SidebarDocItem(id: "itm_1", section: machine, body: .workspace(ref("ws-1"))),
        ])
        let rows = [SidebarDocRow(key: "itm_1", kind: "item", section: machine, item: "itm_1", ref: ref("ws-1"))]
            + (withApp ? [SidebarDocRow(key: app, kind: "section", section: app)] : [])
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

    /// The document gains the app section (the daemon placed it) while the live rows stay the same: the rows'
    /// pass (`SidebarRows.show(unlessShown:)`) skips a set while the arrangement is current, so a section with no
    /// rows of its own never reached the list until a workspace changed.
    @Test func aDocumentSectionAddedWithNoRowsMakesTheArrangementStale() {
        let store = SidebarDocStore(remote: nil)
        store.shown = Self.projection(withApp: false)
        let model = SidebarModel()
        model.docDrag = SidebarDocDrag(document: store, item: { _ in nil }, section: { id in id == .machine(.local) ? Self.machine : nil },
                                       begin: { _ in [:] }, drop: { _, _ in })
        model.setSections(Self.raw())
        #expect(model.arrangementIsCurrent)
        store.shown = Self.projection()
        #expect(!model.arrangementIsCurrent, "the list still arranges the document without the app section")
        model.setSections(Self.raw())
        #expect(model.arrangementIsCurrent)
        #expect(model.sections.map(\.id).last == .custom(Self.app))
    }
}
