import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// POLISH audit, batch 4 (cx-2grmt): the page info bubble appeared and left in one frame. It
/// opens and closes like every native popup (`PopupFade`), and a reopen during the close keeps it.
@MainActor @Suite(.serialized) struct PageInfoMotionTests {
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// A window on screen with an omnibar button, and a bubble controller for an https page.
    static func bubble() throws -> (NSWindow, PageInfoController) {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 500, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let button = NSView(frame: NSRect(x: 20, y: 340, width: 24, height: 24))
        window.contentView?.addSubview(button)
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        let tab = HibernatedBrowserTab(id: BrowserTabID(rawValue: "tab"), engine: .webkit, profile: BrowserProfileID(rawValue: UUID()),
                                       state: BrowserTabState(url: URL(string: "https://example.com"), title: "Example"),
                                       favicon: nil, restoreState: .webKit(Data()), snapshot: nil)
        return (window, PageInfoController(tab: { tab }, anchor: { button }))
    }

    /// Waits for `condition` up to `timeout`: the fade's end, which a loaded host (the hosted
    /// macOS 27 lane ran this suite in 23 s) can deliver well after its 0.15 s duration.
    static func until(_ condition: () -> Bool, within timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    static func panel(of window: NSWindow) throws -> PageInfoPanel {
        try #require(NSApp.windows.compactMap { $0 as? PageInfoPanel }.first { $0.parent === window })
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func theBubbleOpensAndClosesWithMotion() async throws {
        let (window, controller) = try Self.bubble()
        defer { window.orderOut(nil) }
        // Synchronous inside: the override is process-wide.
        let (panel, opened) = try { () throws -> (PageInfoPanel, Bool) in
            Motion.reduceMotionOverride = false
            defer { Motion.reduceMotionOverride = nil }
            controller.perform(.show(.main))
            let panel = try Self.panel(of: window)
            return (panel, panel.contentView?.layer?.animation(forKey: "sublayerTransform") != nil)
        }()
        #expect(opened, "opened in one frame")
        controller.close()
        #expect(panel.isVisible, "closed in one frame")
        #expect(!controller.isShown, "a closing bubble still counts as shown (the button would not reopen it)")
        // Review: keys and clicks go back to the page now, not when the fade ends.
        #expect(!panel.isKeyWindow, "the fading bubble still takes keys")
        #expect(panel.ignoresMouseEvents, "the fading bubble still takes clicks")
        try await Self.until { !panel.isVisible && panel.parent == nil }
        #expect(!panel.isVisible)
        #expect(panel.parent == nil)
    }

    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aReopenDuringTheCloseKeepsTheBubble() async throws {
        let (window, controller) = try Self.bubble()
        defer { window.orderOut(nil) }
        controller.perform(.show(.main))
        let panel = try Self.panel(of: window)
        controller.close()
        controller.perform(.show(.main))
        // Another suite's window taking key while this runs in parallel closes the bubble, as it
        // should (`onKeyElsewhere`, `onResignKey`); this test is about the fade only (cx-7l2nc).
        panel.onKeyElsewhere = nil
        panel.onResignKey = nil
        try await Self.until { panel.alphaValue == 1 }
        // Past the earlier close's end, so a late completion of it would show here.
        try await Task.sleep(for: .milliseconds(600))
        #expect(panel.isVisible, "the earlier close took the reopened bubble away")
        #expect(panel.alphaValue == 1)
        #expect(controller.isShown)
        #expect(!panel.ignoresMouseEvents, "the reopened bubble takes no clicks")
        controller.close()
    }
}
