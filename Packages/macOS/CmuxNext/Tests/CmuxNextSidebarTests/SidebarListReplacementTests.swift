import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// An extension's workspace list (`cmux.sidebar/1`, opt-in through `sidebar.workspaceListApp`) draws in
/// place of the built-in list only while it is mounted, drawn and not failing. In every other case
/// (none chosen, the app removed, still loading, a script error, a crash, apps turned off or safe
/// mode) the sidebar draws the built-in list, unchanged.
@MainActor @Suite struct SidebarListReplacementTests {
    final class FakeContent: SidebarCustomContent {
        let view = NSView()
        var isReady = true
        var errorText: String?
        var onChange: (() -> Void)?
        var released = false
        func preferredHeight(width: CGFloat) -> CGFloat { 0 }
        func release() { released = true }
    }

    final class FakeReplacement: SidebarListReplacement {
        var content: (any SidebarCustomContent)? { didSet { onContentChange?() } }
        var onContentChange: (() -> Void)?
        init(_ content: (any SidebarCustomContent)?) { self.content = content }
        func release() {}
    }

    private func sidebar() -> SidebarView {
        let sidebar = SidebarView(model: SidebarModel(sections: []), design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    private func draw(_ sidebar: SidebarView) {
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
    }

    @Test func withNoExtensionChosenTheBuiltInListDraws() {
        let sidebar = sidebar()
        #expect(sidebar.listReplacement == nil)
        #expect(!sidebar.edgeFade.isHidden)
        #expect(sidebar.listSwap.shown == nil)
    }

    @Test func aDrawnExtensionListTakesTheBuiltInListsPlace() {
        let sidebar = sidebar()
        let content = FakeContent()
        sidebar.listReplacement = FakeReplacement(content)
        draw(sidebar)
        #expect(content.view.superview === sidebar)
        #expect(content.view.frame == sidebar.edgeFade.frame)
        #expect(sidebar.edgeFade.isHidden)
    }

    @Test func whileTheExtensionLoadsTheBuiltInListStays() {
        let sidebar = sidebar()
        let content = FakeContent()
        content.isReady = false
        sidebar.listReplacement = FakeReplacement(content)
        draw(sidebar)
        #expect(content.view.superview == nil)
        #expect(!sidebar.edgeFade.isHidden)
    }

    @Test func anExtensionThatFailsFallsBackToTheBuiltInList() {
        let sidebar = sidebar()
        let content = FakeContent()
        let replacement = FakeReplacement(content)
        sidebar.listReplacement = replacement
        draw(sidebar)
        #expect(sidebar.edgeFade.isHidden)

        // A script error or a crash: the mount reports it, and the sidebar draws its own list again.
        content.errorText = "Line 2, column 12: expecting ';'"
        replacement.onContentChange?()
        draw(sidebar)
        #expect(content.view.superview == nil)
        #expect(!sidebar.edgeFade.isHidden)
        #expect(sidebar.listSwap.shown == nil)
    }

    @Test func anExtensionThatIsRemovedFallsBackToTheBuiltInList() {
        let sidebar = sidebar()
        let content = FakeContent()
        let replacement = FakeReplacement(content)
        sidebar.listReplacement = replacement
        draw(sidebar)
        #expect(sidebar.edgeFade.isHidden)

        // The app was uninstalled, hidden, or the setting was cleared.
        replacement.content = nil
        draw(sidebar)
        #expect(content.view.superview == nil)
        #expect(!sidebar.edgeFade.isHidden)
    }

    @Test func droppingTheReplacementBringsTheBuiltInListBack() {
        let sidebar = sidebar()
        let content = FakeContent()
        sidebar.listReplacement = FakeReplacement(content)
        draw(sidebar)
        sidebar.listReplacement = nil
        draw(sidebar)
        #expect(content.view.superview == nil)
        #expect(!sidebar.edgeFade.isHidden)
    }
}
