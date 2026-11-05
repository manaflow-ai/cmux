import AppKit
@testable import CmuxNextBrowserHost
import Testing

/// Background browser use (user 2026-11-05: an agent drives tabs that are not visible or in focus).
/// A tab of a parked workspace stays in its window, hidden in place under a hidden ancestor. Its
/// page ran no animation frame and fired timers once a second, so an agent's `click` (a timed
/// pointer walk) ran past its deadline: the render window took only a chrome with no window or
/// one hidden itself. Real AppKit views and windows; no app, no page.
@MainActor @Suite struct AgentRenderWindowsHiddenTabTests {
    /// A window whose workspace container holds `chrome`, as a pane holds a tab's chrome.
    private func windowHolding(_ chrome: NSView) -> (window: NSWindow, workspace: NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let workspace = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(workspace)
        workspace.addSubview(chrome)
        return (window, workspace)
    }

    @Test func aTabOfAParkedWorkspaceRendersInTheRenderWindow() {
        let windows = AgentRenderWindows()
        let chrome = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let (window, workspace) = windowHolding(chrome)
        // The workspace is parked: hidden in place, still in the window.
        workspace.isHidden = true
        #expect(chrome.isHiddenOrHasHiddenAncestor && !chrome.isHidden)
        #expect(windows.keepRendering(tabID: "tab_parked", chrome: chrome, webView: nil))
        #expect(chrome.window?.identifier == NSUserInterfaceItemIdentifier("cmux.agentRenderWindow"))
        #expect(chrome.window !== window)
        #expect(!chrome.isHiddenOrHasHiddenAncestor)
        windows.release(tabID: "tab_parked")
        window.close()
    }

    /// A WebKit page in a minimized or fully covered window is hidden too: no animation frame, a
    /// timer a second, and an agent's click timed out. A window never ordered on screen draws
    /// nothing either.
    @Test func aTabOfAWindowThatDrawsNothingRendersInTheRenderWindow() {
        let windows = AgentRenderWindows()
        let chrome = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let (window, _) = windowHolding(chrome)
        #expect(!window.isVisible)
        #expect(windows.keepRendering(tabID: "tab_covered", chrome: chrome, webView: nil))
        #expect(chrome.window?.identifier == NSUserInterfaceItemIdentifier("cmux.agentRenderWindow"))
        windows.release(tabID: "tab_covered")
        window.close()
    }

    @Test func aTabAWindowShowsStaysWhereItIs() {
        let windows = AgentRenderWindows()
        let chrome = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let (window, _) = windowHolding(chrome)
        #expect(!windows.keepRendering(tabID: "tab_shown", chrome: chrome, webView: nil))
        #expect(chrome.window === window)
        window.close()
    }

    @Test func aPaneTakesItsTabBackFromTheRenderWindow() {
        let windows = AgentRenderWindows()
        let chrome = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let (window, workspace) = windowHolding(chrome)
        workspace.isHidden = true
        #expect(windows.keepRendering(tabID: "tab_back", chrome: chrome, webView: nil))
        // The workspace shows again and its pane adds the chrome back.
        workspace.isHidden = false
        workspace.addSubview(chrome)
        #expect(chrome.window === window)
        // A second agent call finds the tab shown: it stays in the pane.
        #expect(!windows.keepRendering(tabID: "tab_back", chrome: chrome, webView: nil))
        window.close()
    }
}
