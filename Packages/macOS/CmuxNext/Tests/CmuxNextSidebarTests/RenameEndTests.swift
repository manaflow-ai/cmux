import AppKit
import Testing
@testable import CmuxNextSidebar

/// Ending an inline rename (commit or cancel) tells the host, which gives
/// the keyboard back to the focused content (plans/cmux-next/focus.md R8).
@MainActor @Suite struct RenameEndTests {
    @Test func commitAndCancelBothReportTheEnd() {
        let sidebar = SidebarView(model: SidebarModel(sections: fixture(), activeWorkspaceID: id("a")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        sidebar.frame = window.contentView!.bounds
        window.contentView!.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        var ends: [Bool] = []
        sidebar.onRenameEnded = { ends.append($0) }
        sidebar.beginRename(workspace: id("a"))
        #expect(sidebar.list.inlineRename.session != nil)
        sidebar.list.inlineRename.end(commit: true)
        sidebar.beginRename(workspace: id("a"))
        sidebar.list.inlineRename.session?.cancelled = true
        sidebar.list.inlineRename.end(commit: false, byKeyboard: true)
        #expect(ends == [false, true])
        #expect(sidebar.list.inlineRename.session == nil)
    }
}
