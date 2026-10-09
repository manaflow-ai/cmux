import AppKit
import Testing
@testable import CmuxNextSidebar

/// An app section removed from the layout releases its content (the App
/// unmounts it on the app supervisor); a section that only collapses or
/// moves keeps it.
@MainActor @Suite struct SidebarAppSectionReleaseTests {
    final class Provider: SidebarAppSectionProvider {
        var onContentChange: (() -> Void)?
        var released: [String] = []
        var views: [String: NSView] = [:]
        func title(for contribution: String) -> String? { contribution }
        func makeView(for contribution: String) -> NSView? {
            if let view = views[contribution] { return view }
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
            views[contribution] = view
            return view
        }
        func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat { 40 }
        func release(_ contribution: String) {
            released.append(contribution)
            views[contribution] = nil
        }
    }

    @Test func aSectionLeavingTheLayoutReleasesItsContent() {
        let model = SidebarModel()
        model.layout = SidebarLayoutDocument.defaults.chatsLayout(enabled: true)
        let sidebar = SidebarView(model: model)
        let provider = Provider()
        sidebar.appSections = provider
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.layout()
        #expect(provider.views[SidebarChatsView.contribution] != nil)
        #expect(provider.released.isEmpty)
        sidebar.layout()
        #expect(provider.released.isEmpty, "a relayout keeps the content")
        model.layout = SidebarLayoutDocument.defaults.chatsLayout(enabled: false)
        sidebar.needsLayout = true
        sidebar.layout()
        #expect(provider.released == [SidebarChatsView.contribution])
    }
}
