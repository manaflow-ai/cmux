@testable import CmuxNextApp
import CmuxNextActions
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-22 (ask-890db939a2): "why is there even a remove from top option. just move it yourself. you can drag
/// it anywhere you want." A top row's menu has no Remove from Top (it is dragged out); a pinned tile keeps Unpin;
/// a workspace row's menu has no Add to Top (it is dragged in).
@MainActor
@Suite struct TopRowMenuDragTests {
    private static let pinned = LayoutItemID("itm_pin")
    private static let document = SidebarLayoutDocument(sections: SidebarLayoutDocument.defaults.sections + [
        SidebarLayoutDocument.pinnedSection(items: [LayoutItem(id: pinned, ref: .app("cmux/app-store"))]),
    ])

    @Test func aTopRowMenuHasNoRemoveFromTop() {
        #expect(Self.document.isTopRow(LayoutItemID("itm_home")))
    }

    @Test func aPinnedTileAndABottomItemKeepTheirRemove() {
        #expect(!Self.document.isTopRow(Self.pinned))
        #expect(!Self.document.isTopRow(LayoutItemID("itm_account")))
    }

    /// The + button's menu (ask-890db939a2, "we want to hide? we want to do something? pick a fucking option"):
    /// only the rows that make something, no view toggle, no empty folder, no stray separator.
    @Test func thePlusMenuOnlyMakesThings() {
        let makes: Set<ActionID> = ["newBrowserWorkspace", "workspace.newAtTop"]
        let entries: [ContextMenuEntry] = [
            .separator, .action("newBrowserWorkspace"), .separator, .separator, .action("sidebar.minimal.on"),
            .folder(MenuFolder.new, [.action("workspace.newAtTop"), .action("sidebar.customize")]),
            .folder(MenuFolder.options, [.action("sidebar.noFade.on")]), .separator,
        ]
        #expect(ContextMenuCatalog.keeping(entries, makes.contains) == [
            .action("newBrowserWorkspace"), .separator, .folder(MenuFolder.new, [.action("workspace.newAtTop")]),
        ])
    }
}
