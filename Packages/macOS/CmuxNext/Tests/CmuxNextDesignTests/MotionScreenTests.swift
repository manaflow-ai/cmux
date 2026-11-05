import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Child panels used for overlays can be attached to a visible window before AppKit assigns them
/// a screen. Motion must use the visible parent in that short interval so a fade does not snap.
@MainActor @Suite(.serialized, .closesItsWindows) struct MotionScreenTests {
    static func hasLiveDisplay() -> Bool {
        guard let screen = NSScreen.main else { return false }
        return !DisplaySleep.shared.isAsleep(screen)
    }

    @Test(.enabled("a live display is required for AppKit screen routing") { await Self.hasLiveDisplay() })
    func aChildPanelUsesItsVisibleParentScreenForMotion() throws {
        let parent = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 500, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        parent.orderFrontRegardless()
        let parentScreen = try #require(parent.screen)
        try #require(!DisplaySleep.shared.isAsleep(parentScreen))

        // Keep the child off-screen and unshown: this matches the overlay-panel interval before
        // AppKit publishes the child's own screen, while its parent is already visible.
        let panel = NSPanel(contentRect: NSRect(x: 10_000, y: 10_000, width: 100, height: 100),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let view = NSView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView = view
        parent.addChildWindow(panel, ordered: .above)
        defer {
            parent.removeChildWindow(panel)
            panel.close()
        }
        try #require(panel.screen == nil)

        #expect(Motion.canAnimate(in: view))
    }
}
