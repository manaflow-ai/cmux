import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import Testing

/// While the overlay panel is detached, the agent cursor layer is in the
/// window root view and must stay its top subview: a view added later (the
/// titlebar badge is added `.above`) never covers the cursors.
@MainActor @Suite(.serialized) struct AgentCursorTopmostTests {
    @Test func aLaterSubviewNeverCoversTheCursor() {
        _ = NSApplication.shared
        let model = SidebarModel()
        let root = WindowRootView(sidebar: SidebarContainerView(model: model), reduceTransparency: { false }, applyWindowBlur: { _, _ in })
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1000, height: 700),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        let host = WindowOverlayHost.host(for: window)
        let layer = host.agentCursorLayer
        #expect(root.subviews.last?.layer === layer.superlayer, "the cursor view is the root's top subview")

        root.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20)), positioned: .above, relativeTo: nil)
        #expect(root.subviews.last?.layer === layer.superlayer, "re-raised above a later subview")
        root.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20)))
        #expect(root.subviews.last?.layer === layer.superlayer)
    }
}
