import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// NIGHTLY, Lawrence 2026-11-16 ("as i was typing, we lost focus of left terminal"): an agent drove a background
/// Chromium tab, which the App parks in an agent render window (off every screen, never key) so it renders. A focus
/// ask the page carried there was granted: CEF's SetFocus made the page window, a child of the render window, key, and
/// the keys left the terminal the person typed in. A parked page takes no focus; its ask waits until a pane shows it.
extension CEFDeferredFocusTests {
    @Test func aPageParkedInAnAgentRenderWindowTakesNoFocus() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 41)
        let render = Self.renderWindow()
        defer { render.closeAfterTest() }
        try #require(render.contentView).addSubview(tab.contentView)
        Self.endTurn()

        tab.setFocused(true)
        Self.endTurn()
        #expect(FocusSpyShim.granted.isEmpty, "a page parked in an agent render window took focus: \(FocusSpyShim.granted)")
    }

    @Test func anAskCarriedIntoAnAgentRenderWindowIsNotGrantedThere() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 42)
        tab.setFocused(true) // asked while in no window: kept
        let render = Self.renderWindow()
        defer { render.closeAfterTest() }

        try #require(render.contentView).addSubview(tab.contentView)
        Self.endTurn()
        #expect(FocusSpyShim.granted.isEmpty, "a kept ask was granted in an agent render window: \(FocusSpyShim.granted)")
    }

    /// An agent render window as `AgentRenderPanel` makes it: left of and below every screen.
    static func renderWindow() -> NSWindow {
        let screens = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        let origin = screens.isNull ? NSPoint(x: -20_000, y: -20_000) : NSPoint(x: screens.minX - 11_280, y: screens.minY - 10_800)
        let window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 400, height: 300)),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.identifier = .agentRenderWindow
        return window
    }
}
