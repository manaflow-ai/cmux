@testable import CmuxNextApp
import CmuxNextSidebar
import Testing

/// R119: Cmd-Ctrl-[ / ] step from what the window shows. Any app or built-in
/// item whose page the focused tab shows (App Store, CodeRouter, an app page,
/// a Settings tab) is the current item, ahead of Home and pinned workspaces.
@MainActor
struct SidebarCurrentItemTests {
    static let layout = SidebarLayoutDocument(sections: [
        LayoutSection(id: LayoutSectionID("top"), region: .top, items: [
            LayoutItem(id: LayoutItemID("home"), ref: .app("cmux/home")),
            LayoutItem(id: LayoutItemID("store"), ref: .app("cmux/app-store")),
            LayoutItem(id: LayoutItemID("router"), ref: .app("cmux/coderouter")),
            LayoutItem(id: LayoutItemID("notes"), ref: .app("acme/notes")),
            LayoutItem(id: LayoutItemID("pin"), ref: .workspace("s:ws_1")),
        ]),
        LayoutSection(id: LayoutSectionID("bottom"), region: .bottom, items: [
            LayoutItem(id: LayoutItemID("settings"), ref: .builtIn(.settings)),
        ]),
    ])

    static func current(page: InternalPageID? = nil, workspace: String? = nil, homeActive: Bool = false,
                        cursor: (LayoutItemID, String?)? = nil) -> String? {
        var info: [LayoutItemID: SidebarItemInfo] = [:]
        if homeActive { info[LayoutItemID("home")] = SidebarItemInfo(title: "Home", symbol: "house", isActive: true) }
        return SidebarItemStepper.currentLayoutItem(in: layout, itemInfo: info, shownWorkspace: workspace, shownPage: page, cursor: cursor)?.rawValue
    }

    @Test func aShownPageMakesItsItemCurrent() {
        #expect(Self.current(page: .appStore, homeActive: true) == "store", "the shown App Store beats Home")
        #expect(Self.current(page: .coderouter) == "router")
        #expect(Self.current(page: InternalPageID(rawValue: "app:acme/notes")) == "notes")
        #expect(Self.current(page: .settings) == "settings")
    }

    @Test func otherwiseHomeThenAPinnedWorkspaceThenTheCursor() {
        #expect(Self.current(page: .keybindings, homeActive: true) == "home")
        #expect(Self.current(workspace: "s:ws_1") == "pin")
        #expect(Self.current(workspace: "s:ws_2", cursor: (LayoutItemID("router"), "s:ws_2")) == "router")
        #expect(Self.current(workspace: "s:ws_3", cursor: (LayoutItemID("router"), "s:ws_2")) == nil, "the cursor ends when the shown workspace changes")
        #expect(Self.current() == nil)
    }
}
