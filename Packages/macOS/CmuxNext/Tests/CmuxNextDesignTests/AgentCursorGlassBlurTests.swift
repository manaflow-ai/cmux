import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Real blur for the agent cursor's name tag (user, 2026-10-20: "get a real
/// blur in the app"). The cursor draws in the overlay panel, a window above
/// the Chromium page windows, so a behind-window visual effect view in that
/// panel blurs the page under the tag; a mask layer cuts it to the tag shapes.
@MainActor
@Suite(.closesItsWindows)
struct AgentCursorGlassBlurTests {
    @Test func theCursorGlassBlursWhatIsBehindTheOverlayWindow() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        defer { window.closeWithOverlayHost() }
        let host = WindowOverlayHost.host(for: window)
        let cursorLayer = host.agentCursorLayer
        let mask = host.agentCursorGlassLayer
        let carrier = try #require(host.agentCursorCarrier)
        let glass = try #require(carrier.subviews.compactMap { $0 as? NSVisualEffectView }.first, "a visual effect view")
        #expect(glass.blendingMode == .withinWindow, "no panel: blurs the window's own views, never the desktop")
        #expect(glass.state == .active, "keeps blurring while another window is key")
        #expect(glass.material == .hudWindow)
        #expect(glass.layer?.mask === mask, "cut to the tag shapes")
        #expect(mask.isGeometryFlipped, "y-down like the cursor layer")
        let top = try #require(carrier.subviews.last)
        #expect(top !== glass && top.layer?.sublayers?.contains { $0 === cursorLayer } == true, "the cursor draws over its glass")
        #expect(carrier.hitTest(NSPoint(x: 10, y: 10)) == nil, "still never takes the mouse")

        host.setPlanesWantPanel(true)
        #expect(host.isPanelAttached)
        #expect(carrier.window === host.panel, "the cursor moved to the panel above the page windows")
        #expect(glass.blendingMode == .behindWindow, "blurs the page windows under the overlay panel")
        #expect(glass.layer?.mask === mask)
        host.setPlanesWantPanel(false)
        #expect(glass.blendingMode == .withinWindow)
    }

    /// Leo, 2026-11-20: "me moving my mouse is slow, even scrolling thru claude code desktop is slow (cmux next
    /// still slower unfortunately)". An active full-window glass makes WindowServer blur the backdrop on every
    /// frame under it, so it sleeps (hidden) while no cursor shows a blur well: before the first cursor, after
    /// one hides or goes, and once its idle fade ends.
    @Test func theCursorGlassSleepsWhileNoCursorShows() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        defer { window.closeWithOverlayHost() }
        let host = WindowOverlayHost.host(for: window)
        let mask = host.agentCursorGlassLayer
        let carrier = try #require(host.agentCursorCarrier)
        let glass = carrier.glassView
        #expect(glass.isHidden, "no cursor yet: nothing to blur")

        let root = CALayer()
        mask.addSublayer(root)
        host.agentCursorTagsDidChange()
        #expect(!glass.isHidden, "a shown cursor wakes the glass")

        root.isHidden = true
        host.agentCursorTagsDidChange()
        #expect(glass.isHidden, "a hidden cursor puts it back to sleep")

        root.isHidden = false
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.05
        fade.beginTime = root.convertTime(CACurrentMediaTime(), from: nil) + 0.05
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        root.add(fade, forKey: "idleHide")
        host.agentCursorTagsDidChange()
        #expect(!glass.isHidden, "still shown while its idle fade waits and plays")
        let deadline = Date().addingTimeInterval(3)
        while !glass.isHidden, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(glass.isHidden, "asleep once the fade ends, with no new cursor event")

        root.removeAnimation(forKey: "idleHide")
        host.agentCursorTagsDidChange()
        #expect(!glass.isHidden, "the next action wakes it")
        root.removeFromSuperlayer()
        host.agentCursorTagsDidChange()
        #expect(glass.isHidden, "a removed cursor leaves nothing to blur")
    }
}
