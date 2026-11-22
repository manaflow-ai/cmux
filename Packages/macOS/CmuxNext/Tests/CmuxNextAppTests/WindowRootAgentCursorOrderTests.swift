import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import Testing

/// The real window root keeps the agent cursor carrier on top while the
/// overlay panel is detached: an add, a `subviews =` assignment, and a
/// `sortSubviews` caught by the next layout pass.
@MainActor @Suite(.serialized) struct WindowRootAgentCursorOrderTests {
    init() { _ = NSApplication.shared }

    private func makeWindow() -> (NSWindow, WindowRootView) {
        let model = SidebarModel()
        model.width = 240
        let root = WindowRootView(sidebar: SidebarContainerView(model: model), reduceTransparency: { false }, applyWindowBlur: { _, _ in })
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1000, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.orderFrontRegardless()
        return (window, root)
    }

    private func carrier(_ host: WindowOverlayHost, in root: NSView) -> NSView? {
        let superlayer = host.agentCursorLayer.superlayer
        return root.subviews.first { $0.layer === superlayer }
    }

    @Test func theRootKeepsTheCursorOnTop() throws {
        let (window, root) = makeWindow()
        defer { window.close() }
        let host = WindowOverlayHost.host(for: window)
        _ = host.agentCursorLayer
        let cursor = try #require(carrier(host, in: root))
        #expect(root.subviews.last === cursor)

        root.addSubview(NSView(frame: .zero))
        #expect(root.subviews.last === cursor, "after an add")

        root.subviews = root.subviews.reversed()
        #expect(root.subviews.last === cursor, "after a subviews assignment")

        root.sortSubviews({ a, b, _ in a === b ? .orderedSame : (ObjectIdentifier(a) < ObjectIdentifier(b) ? .orderedAscending : .orderedDescending) },
                          context: nil)
        root.layout()
        #expect(root.subviews.last === cursor, "after a sort, at the next layout pass")
    }
}
