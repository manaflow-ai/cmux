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

    final class Chats: SidebarAppSectionProvider {
        let view = NSView()
        var onContentChange: (() -> Void)?
        func title(for contribution: String) -> String? { "Chats" }
        func makeView(for contribution: String) -> NSView? { contribution == SidebarLayoutDocument.recentsContribution ? view : nil }
        func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat { 3 * Metrics.sidebarRowHeight }
    }

    @Test func hiddenChatsDrawsNothing() {
        let chats = SidebarLayoutDocument.defaults.chatsLayout(enabled: true)
        for (layout, drawn) in [(chats, true), (chats.chatsLayout(enabled: false), false)] {
            let model = SidebarModel(sections: SidebarDemoMock.makeSections())
            model.layout = layout
            let view = SidebarView(model: model)
            let provider = Chats()
            view.appSections = provider
            view.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
            view.layoutSubtreeIfNeeded()
            #expect((provider.view.superview === view.belowRegion) == drawn)
        }
    }
}
