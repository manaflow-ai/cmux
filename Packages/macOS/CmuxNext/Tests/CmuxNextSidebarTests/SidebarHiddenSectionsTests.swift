import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// Leo (2026-10-06): Hide Section on the Projects header hides it
/// (`sidebar.showProjects`) until Settings or the sidebar's menu shows it
/// again. Hiding Chats turns `sidebar.showChats` off, which takes its section
/// out of the layout.
@MainActor @Suite(.serialized) struct SidebarHiddenSectionsTests {
    @Test func hiddenProjectsLayOutNoRows() {
        var options = SidebarLayoutOptions()
        options.hidesWorkspaces = true
        #expect(SidebarLayout.make(sections: SidebarDemoMock.makeSections(), metrics: .standard, options: options).rows.isEmpty)
    }

    @Test func theModelHidesProjectsFromTheSetting() {
        let model = SidebarModel(sections: SidebarDemoMock.makeSections())
        var preferences = SidebarSectionsPreferences.defaults
        preferences.showProjects = false
        model.applyListPreferences(preferences)
        #expect(model.listOptions().hidesWorkspaces)
        model.applyListPreferences(.defaults)
        #expect(!model.listOptions().hidesWorkspaces)
    }

    @Test func hiddenChatsDrawsNothing() {
        let model = SidebarModel(sections: SidebarDemoMock.makeSections())
        model.layout = SidebarRecentsUnderListTests.layout.chatsLayout(enabled: false)
        let view = SidebarView(model: model)
        view.appSections = SidebarRecentsUnderListTests.Recents()
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        view.layoutSubtreeIfNeeded()
        #expect(view.list.trailer.region.layoutResult == .empty)
        #expect(view.list.trailer.height == 0)
    }
}
