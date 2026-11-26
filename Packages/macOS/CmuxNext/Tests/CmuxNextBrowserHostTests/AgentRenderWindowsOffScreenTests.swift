import AppKit
@testable import CmuxNextBrowserHost
import CmuxNextTestSupport
import Testing

/// cmux#56429: a chat's question card ("Answered in chat") floated over Slack. An agent had driven
/// the chat's tab while no pane showed it, so it waited in its render window, off every screen; a
/// display change let AppKit pull that window onto the built-in display, and the Chromium page
/// window it carries drew the page over the person's other windows. A render window stays off
/// every screen. Real AppKit windows; no app, no page.
@MainActor @Suite(.closesItsWindows) struct AgentRenderWindowsOffScreenTests {
    private let screens = [NSRect(x: 0, y: 0, width: 1512, height: 982), NSRect(x: 1512, y: 46, width: 2560, height: 1440)]

    private func parked(_ windows: AgentRenderWindows, _ tabID: String) -> (AgentRenderPanel, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let chrome = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView?.addSubview(chrome)
        #expect(windows.keepRendering(tabID: tabID, chrome: chrome, webView: nil))
        return (windows.panel(for: tabID)!, window)
    }

    private func onAScreen(_ frame: NSRect) -> Bool { screens.contains { $0.intersects(frame) } }

    /// AppKit's constraint, which it applies when it orders a window and when the displays change,
    /// leaves a render window where it is.
    @Test func appKitsConstraintKeepsARenderWindowOffEveryScreen() {
        let windows = AgentRenderWindows(windowDraws: { _ in false })
        let (panel, window) = parked(windows, "tab_constraint")
        let away = AgentRenderWindows.frame(for: AgentRenderWindows.viewport, screens: screens)
        #expect(!onAScreen(away))
        #expect(panel.constrainFrameRect(away, to: NSScreen.main) == away)
        windows.release(tabID: "tab_constraint")
        window.close()
    }

    /// A frame AppKit sets after a display change (the issue's window sat at -472, -30, on the
    /// built-in display) lands off the screens there are now, keeping its size.
    @Test func aFrameOnAScreenGoesOffTheScreensAgain() {
        let windows = AgentRenderWindows(windowDraws: { _ in false })
        let (panel, window) = parked(windows, "tab_display")
        let now = NSScreen.screens.map(\.frame)
        let away = AgentRenderWindows.frame(for: AgentRenderWindows.viewport, screens: now)
        panel.setFrameOrigin(NSPoint(x: -472, y: -30))
        #expect(panel.frame == away)
        panel.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 800), display: false)
        #expect(panel.frame == AgentRenderWindows.frame(for: NSSize(width: 1200, height: 800), screens: now))
        #expect(!now.contains { $0.intersects(panel.frame) })
        windows.release(tabID: "tab_display")
        window.close()
    }
}
