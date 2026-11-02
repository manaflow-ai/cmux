@testable import CmuxNextSidebar
import Testing

/// Folding the Chief group dropped the whole sidebar about 52 pt (Home at y 96, not 44), an empty band
/// at the top, while the sidebar document was active (#23638's folded captures). The Chief group's
/// chevron folds a section (`.toggleCollapse(.section)`), and the model applied the fold by arranging
/// its already arranged sections again: the document's sections above the machine lists (Pinned,
/// Home's block) came twice, and the second copy took their rows. A fold changes only what folds.
@MainActor @Suite(.serialized) struct ChiefGroupFoldShiftTests {
    static let chiefID = MachineID("server-host_chief6b68ac4a")

    /// This Mac (the document's machine section) and the Chief group, as the app maps them.
    static func sections() -> [SidebarSection] {
        let local = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(SidebarWorkspace(id: WorkspaceID("ws-1"), title: "loose")),
            .group(SidebarGroup(id: GroupID("itm_gp"), name: "Pinned one",
                                workspaces: [SidebarWorkspace(id: WorkspaceID("ws-0"), title: "pinned")])),
            .group(SidebarGroup(id: GroupID("itm_gm"), name: "Loose one",
                                workspaces: [SidebarWorkspace(id: WorkspaceID("ws-2"), title: "grouped")])),
        ])
        let chief = SidebarSection(kind: .machine(SidebarMachine(id: Self.chiefID, name: "Chief", kind: .server)), nodes: [
            .workspace(SidebarWorkspace(id: WorkspaceID("a14"), machineID: Self.chiefID, title: "Native workflows runtime")),
        ])
        return [local, chief]
    }

    /// A model on an active document (`SidebarDocPinnedGroupTests.projection`: a Pinned band above This Mac).
    static func withDocument(_ body: (SidebarModel) throws -> Void) rethrows {
        let store = SidebarDocStore(remote: nil, mirror: nil)
        store.shown = SidebarDocPinnedGroupTests.projection()
        let model = SidebarModel()
        model.docDrag = SidebarDocDrag(document: store, item: { key in
            if case let .workspace(id) = key { return "itm_" + id.rawValue.dropFirst(3) }
            return nil
        }, section: { id in id == .machine(.local) ? SidebarDocPinnedGroupTests.machine : nil },
        begin: { _ in [:] }, drop: { _, _ in })
        model.setSections(sections()) // the raw mapping, as SidebarRows.show sets it
        try body(model)
    }

    static func shape(_ sections: [SidebarSection]) -> [String] {
        sections.map { "\($0.id)\($0.nodes.isEmpty ? " (empty)" : "")" }
    }

    @Test func foldingTheChiefGroupKeepsEverySectionOnce() {
        Self.withDocument { model in
            let before = Self.shape(model.sections)
            model.apply(.toggleCollapse(.section(.machine(Self.chiefID))))
            #expect(model.section(.machine(Self.chiefID))?.isCollapsed == true, "the Chief group did not fold")
            #expect(Self.shape(model.sections) == before, "folding the Chief group changed the sections")
            model.apply(.toggleCollapse(.section(.machine(Self.chiefID))))
            #expect(model.section(.machine(Self.chiefID))?.isCollapsed == false, "the Chief group did not open")
            #expect(Self.shape(model.sections) == before, "opening the Chief group changed the sections")
        }
    }

    /// The layout of the folded sidebar: its top rows start where they did, and no row comes twice.
    @Test func foldingTheChiefGroupKeepsTheTopRowsInPlace() {
        Self.withDocument { model in
            var options = SidebarLayoutOptions()
            options.flattensMachines = true
            options.blockHeights = [SidebarDocPinnedGroupTests.pinned: 52]
            let open = SidebarLayout.make(sections: model.sections, metrics: .standard, options: options)
            model.apply(.toggleCollapse(.section(.machine(Self.chiefID))))
            let folded = SidebarLayout.make(sections: model.sections, metrics: .standard, options: options)
            let keys = folded.rows.map(\.key)
            #expect(Set(keys).count == keys.count, "a row comes twice: \(keys)")
            let first = open.rows.first.map(\.key)
            #expect(folded.rows.first?.key == first)
            #expect(folded.rows.first?.y == open.rows.first?.y,
                    "the top row moved from \(open.rows.first?.y ?? -1) to \(folded.rows.first?.y ?? -1) pt")
            let header = SidebarRowKey.section(.machine(Self.chiefID))
            #expect(folded.row(for: header)?.y == open.row(for: header)?.y, "the Chief header moved")
        }
    }
}
