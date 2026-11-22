import AppKit
import CmuxNextBrowser
@testable import CmuxNextBrowserHost
import CmuxNextTestSupport
import Testing

/// Background browser use (user 2026-11-05: an agent drives tabs that are not visible or in focus).
/// A tab of a parked workspace stays in its window, hidden in place under a hidden ancestor. Its
/// page ran no animation frame and fired timers once a second, so an agent's `click` (a timed
/// pointer walk) ran past its deadline: the render window took only a chrome with no window or
/// one hidden itself. Real AppKit views and windows; no app, no page.
@MainActor @Suite(.closesItsWindows) struct AgentRenderWindowsHiddenTabTests {
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

    /// A pane's refresh after the agent navigated (the tab's title changed) pulled the tab back into
    /// its minimized window mid-call, and the agent's next click timed out there. While that window
    /// draws nothing the tab stays off screen; once it draws, the pane may take it back.
    @Test func aTabStaysOffScreenWhileItsPanesWindowDrawsNothing() {
        let windows = AgentRenderWindows(windowDraws: { _ in false })
        let chrome = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let (window, workspace) = windowHolding(chrome)
        #expect(windows.keepRendering(tabID: "tab_refresh", chrome: chrome, webView: nil))
        // A window ordered on no screen draws nothing.
        #expect(chrome.staysParked(awayFrom: workspace))
        window.setFrame(NSRect(x: 0, y: 0, width: 400, height: 300), display: false)
        window.orderFrontRegardless()
        if window.drawsContent { #expect(!chrome.staysParked(awayFrom: workspace)) }
        // A view no render window holds is never kept from its pane.
        let shown = NSView()
        workspace.addSubview(shown)
        #expect(!shown.staysParked(awayFrom: workspace))
        windows.release(tabID: "tab_refresh")
        window.close()
    }

    @Test func aTabAWindowShowsStaysWhereItIs() {
        let windows = AgentRenderWindows(windowDraws: { _ in true })
        let chrome = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let (window, _) = windowHolding(chrome)
        #expect(!windows.keepRendering(tabID: "tab_shown", chrome: chrome, webView: nil))
        #expect(chrome.window === window)
        window.close()
    }

    @Test func aPaneTakesItsTabBackFromTheRenderWindow() {
        let windows = AgentRenderWindows(windowDraws: { _ in true })
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
    /// The minimized or covered window draws again (its delegate tells the render windows): its
    /// pane gets the tab back, and another window's change does not move it.
    @Test func aWindowThatDrawsAgainTakesItsTabBack() {
        var draws = false
        let windows = AgentRenderWindows(windowDraws: { _ in draws })
        let chrome = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let pane = PaneStandIn(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(contentRect: pane.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(pane)
        pane.addSubview(chrome)
        #expect(windows.keepRendering(tabID: "tab_return", chrome: chrome, webView: nil))
        #expect(chrome.window !== window)
        // Still covered: it stays off screen.
        windows.windowDidChangeOcclusion(window)
        #expect(chrome.window !== window)
        draws = true
        let other = NSWindow(contentRect: pane.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        windows.windowDidChangeOcclusion(other)
        #expect(chrome.window !== window)
        windows.windowDidChangeOcclusion(window)
        #expect(chrome.window === window)
        #expect(pane.takenBack == 1)
        #expect(!windows.keepRendering(tabID: "tab_return", chrome: chrome, webView: nil))
        other.close()
        window.close()
    }
}

/// A pane: it adds a chrome back to itself, as `PaneContentView.show` does.
@MainActor private final class PaneStandIn: NSView, AgentRenderHome {
    private(set) var takenBack = 0

    func takeBack(_ view: NSView) {
        addSubview(view)
        takenBack += 1
    }
}
