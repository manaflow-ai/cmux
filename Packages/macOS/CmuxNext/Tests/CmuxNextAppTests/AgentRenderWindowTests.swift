import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextBrowserAutomation
import CmuxNextDaemon
import Foundation
import Testing

/// A WebKit tab an agent drives while no pane shows it renders in an
/// off-screen render window: outside every screen, invisible, never key for
/// AppKit (it only reports key to WebKit, so focus and hover work), and
/// ordered behind. When a pane shows the tab again it takes the tab's view
/// back and the render window goes away. Before, such a tab had no window:
/// `input.mouse` failed and every locator.click timed out.
@MainActor
struct AgentRenderWindowTests {
    @Test func aHiddenDrivenTabRendersOffScreenUntilAPaneShowsIt() async throws {
        let rig = try await ProviderTabOpenTests.Rig.make()
        let opening = Task { try await rig.tabs.openAutomationTab(url: nil) }
        await BrowserTabTests.settle { !rig.created.created.isEmpty }
        rig.store.apply(snapshot: try ProviderTabOpenTests.tree(surfaces: [5, 9]))
        let page = try await opening.value
        let entry = try #require(rig.services.cache.existingBrowser(page.id.rawValue))
        #expect(page.webView.window == nil, "the background tab has no window")

        #expect(await rig.tabs.keepRendering(page), "a hidden tab moves into a render window")
        let window = try #require(page.webView.window)
        #expect(entry.chrome.window === window, "the tab's chrome moves, so a pane can take it back")
        for screen in NSScreen.screens { #expect(!window.frame.intersects(screen.frame), "outside every screen") }
        #expect(window.alphaValue == 0)
        #expect(!window.canBecomeKey && !window.canBecomeMain, "AppKit focus never moves to it")
        #expect(window.isKeyWindow, "WebKit sees a key window: focus and hover work")
        #expect(window.firstResponder === page.webView)
        #expect(window.ignoresMouseEvents)
        #expect(await rig.tabs.keepRendering(page) == false, "already rendering: nothing moves")

        // A pane shows the tab: it takes the chrome, and the render window goes.
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        pane.addSubview(entry.chrome)
        await BrowserTabTests.settle { !window.isVisible }
        #expect(!window.isVisible, "the render window closed")
        rig.window.teardown()
        withExtendedLifetime(rig) {}
    }
}
