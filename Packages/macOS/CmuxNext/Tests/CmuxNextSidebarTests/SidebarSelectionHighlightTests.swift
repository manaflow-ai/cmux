import AppKit
import Testing
@testable import CmuxNextSidebar

/// SIDEBAR-SELECTION-ONE-MODEL: one highlight for the whole sidebar. Home and
/// the App Store get the same pill workspaces get, and selecting a top item
/// then a workspace moves that one pill (Lawrence: Home/App Store did not get
/// the animated highlight). The list draws no pill of its own and a selected
/// list item draws no fill of its own.
@MainActor @Suite struct SidebarSelectionHighlightTests {
    static func sidebar() -> (SidebarModel, SidebarView) {
        let ws = SidebarWorkspace(id: WorkspaceID("a"), machineID: .local, title: "a", rowState: .live)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Local", kind: .local)),
                                                           nodes: [.workspace(ws)])])
        let sidebar = SidebarView(model: model)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        sidebar.layoutSubtreeIfNeeded()
        return (model, sidebar)
    }

    static func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    @Test func oneHighlightMovesFromATopItemToAWorkspace() async throws {
        let (model, sidebar) = Self.sidebar()
        let pill = sidebar.highlight.view.pillLayer
        model.selectedItem = .topItem(LayoutItemID("itm_app_store"))
        await Self.settle { sidebar.highlight.view.pillLayer.opacity == 1 }
        sidebar.layoutSubtreeIfNeeded()
        let store = try #require(sidebar.aboveRegion.itemView(LayoutItemID("itm_app_store")))
        #expect(pill.opacity == 1, "the App Store item is highlighted")
        #expect(pill.frame == store.convert(store.selectionRect, to: sidebar.highlight.view), "under the App Store item")
        #expect(store.fill == nil, "the item draws no selected fill of its own")

        model.selectedItem = .workspace(WorkspaceID("a"))
        await Self.settle { pill.frame != store.convert(store.selectionRect, to: sidebar.highlight.view) }
        sidebar.layoutSubtreeIfNeeded()
        let row = try #require(sidebar.list.displayed.row(for: .workspace(WorkspaceID("a"))))
        let target = sidebar.list.convert(sidebar.list.frame(for: row), to: sidebar.highlight.view)
        #expect(pill.opacity == 1)
        #expect(pill.frame == target, "the same pill moved under the workspace row")
        #expect(sidebar.list.decorations.pillLayer.opacity == 0, "the list draws no second pill")
    }

    @Test func noSelectionHidesTheHighlight() async {
        let (model, sidebar) = Self.sidebar()
        model.selectedItem = .workspace(WorkspaceID("a"))
        await Self.settle { sidebar.highlight.view.pillLayer.opacity == 1 }
        model.selectedItem = nil
        await Self.settle { sidebar.highlight.view.pillLayer.opacity == 0 }
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.highlight.view.pillLayer.opacity == 0)
    }
}
