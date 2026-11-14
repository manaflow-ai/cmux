import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// A customize section with `"defaultRegion": "middle"` sits after the workspace list in the document.
/// With the document on, the list draws it as a block row under the machine's rows; its app view gets
/// content only once it is in a window, as an app scene does (`AppSceneNativeView` redraws while in one).
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarAppBlockAfterListTests {
    static let app = LayoutSectionID("sec_app_threads")
    static let contribution = "local/customize#cmux.section/1"

    /// An app's view with no content until its scene arrives, which it draws only in a window.
    final class LateView: NSView {
        var onContent: (() -> Void)?
        private(set) var height: CGFloat = 0
        /// The scene's first batch, after the layout that put the view in the window.
        func deliver() {
            guard window != nil else { return }
            height = 120
            onContent?()
        }
    }

    final class Provider: SidebarAppSectionProvider {
        let view = LateView()
        var onContentChange: (() -> Void)? { didSet { view.onContent = onContentChange } }
        func title(for contribution: String) -> String? { "Threads" }
        func makeView(for contribution: String) -> NSView? { contribution == SidebarAppBlockAfterListTests.contribution ? view : nil }
        func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat { view.height }
    }

    @Test func aMiddleAppSectionAfterTheListDrawsAsABlockWithItsContent() throws {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let members = (1...2).map { SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "w\($0)")) }
        let block = CmuxNextSidebar.SidebarSection(kind: .custom(SidebarCustomSection(id: Self.app.rawValue)), nodes: [])
        let model = SidebarModel(sections: [CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: members), block], activeWorkspaceID: nil)
        model.layout = SidebarLayoutDocument(sections: [
            LayoutSection(id: SidebarLayoutDocument.workspacesSectionID, region: .middle, content: .workspaces),
            LayoutSection(id: Self.app, region: .middle, content: .app, contribution: Self.contribution),
        ])
        model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in }, adoptRef: { _ in nil })
        let sidebar = SidebarView(model: model, design: DesignSettings.shared)
        let provider = Provider()
        sidebar.appSections = provider
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        func settle() {
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.fitToClip()
            sidebar.layoutSubtreeIfNeeded()
        }
        settle()
        provider.view.deliver()
        settle()

        let key = SidebarRowKey.block(Self.app.rawValue)
        let row = try #require(sidebar.list.displayed.row(for: key), "no block row for the app section: \(sidebar.list.displayed.rows.map(\.key))")
        let last = try #require(sidebar.list.displayed.rows.last)
        #expect(last.key == key, "the app section draws after the list's rows")
        #expect(provider.view.window != nil, "the app's view is in the window")
        #expect(row.height >= 120, "the block takes the content's height once the view has it: \(row.height)")
        window.close()
    }
}
