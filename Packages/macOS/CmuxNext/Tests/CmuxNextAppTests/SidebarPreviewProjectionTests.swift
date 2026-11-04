@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Testing

@MainActor @Suite(.serialized)
struct SidebarPreviewProjectionTests {
    @Test(arguments: [LayoutItemRef.app("cmux/app-store"), .builtIn(.appStore)])
    func previewRowsHideAfterMachineAndGroupProjectionAndReturn(_ ref: LayoutItemRef) {
        let machine = "sec_m_preview", band = "sec_preview"
        let body: SidebarDocBody = ref.kind == LayoutItemRef.appKind ? .app(ref.value) : .builtin(ref.value)
        let records = SidebarDocRecords(sections: [
            machine: SidebarDocSection(id: machine, kind: .machine(session: "preview")),
            band: SidebarDocSection(id: band, kind: .pinned, region: .top),
        ], items: [
            "machine-store": SidebarDocItem(id: "machine-store", section: machine, body: body),
            "machine-group": SidebarDocItem(id: "machine-group", section: machine, body: .group(name: "Group", color: nil, icon: nil, collapsed: false)),
            "group-store": SidebarDocItem(id: "group-store", section: machine, parent: "machine-group", body: body),
            "band-group": SidebarDocItem(id: "band-group", section: band, body: .group(name: "Pinned", color: nil, icon: nil, collapsed: false)),
            "band-store": SidebarDocItem(id: "band-store", section: band, parent: "band-group", body: body),
            "docs": SidebarDocItem(id: "docs", section: machine, body: .url("https://example.com", title: "Docs")),
        ])
        let projection = SidebarDocProjection(rows: [
            SidebarDocRow(key: "band-group", kind: "group", section: band, item: "band-group"),
            SidebarDocRow(key: "band-store", kind: "item", section: band, parent: "band-group", depth: 1, item: "band-store"),
            SidebarDocRow(key: "machine-store", kind: "item", section: machine, item: "machine-store"),
            SidebarDocRow(key: "machine-group", kind: "group", section: machine, item: "machine-group"),
            SidebarDocRow(key: "group-store", kind: "item", section: machine, parent: "machine-group", depth: 1, item: "group-store"),
            SidebarDocRow(key: "docs", kind: "item", section: machine, item: "docs"),
        ], records: records, revision: 1)
        let store = SidebarDocStore(remote: nil, mirror: nil)
        store.shown = projection
        let model = SidebarModel()
        model.docDrag = SidebarDocDrag(document: store, item: { _ in nil }, section: { _ in machine }, begin: { _ in [:] }, drop: { _, _ in })
        let rows = SidebarRows(model: model, document: { store })
        let raw = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .group(SidebarGroup(id: GroupID("machine-group"), name: "Group", workspaces: [])),
        ])]
        func listed() -> Set<String> { Set(model.sections.flatMap(\.nodes).flatMap(\.listedItems).map(\.id)) }
        let all: Set<String> = ["machine-store", "group-store", "band-store", "docs"]
        rows.show(raw, creating: ([], nil), showAppStore: true)
        #expect(listed() == all)
        // No layout or row changed: only the setting. The projection inserts
        // its links after SidebarRows hands the sections to the model.
        rows.show(raw, creating: ([], nil), unlessShown: true, showAppStore: false)
        #expect(listed() == ["docs"])
        rows.show(raw, creating: ([], nil), unlessShown: true, showAppStore: true)
        #expect(listed() == all)
        #expect(store.shown == projection)
    }
}
