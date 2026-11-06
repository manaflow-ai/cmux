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
}
