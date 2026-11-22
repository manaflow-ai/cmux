import AppKit
import Testing
@testable import CmuxNextBrowser

/// A pane parks a Chromium tab it stops showing: the tab's content view
/// stays in the window, hidden (PaneContentView+Parking, cx-asb1). An agent
/// that drives such a tab needs the render window as for a tab with no
/// window, unless the pane shows another tab of the same Chromium window.
@MainActor
@Suite(.serialized) struct CEFParkedRenderWindowTests {
    private func rig() -> (CEFTab, CEFTab, NSView, NSWindow) {
        let runtime = CEFRuntime.shared
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: "parked"), profile: .default), runtime: runtime)
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        let second = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.add(second)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // The parked chrome around the first tab's content view.
        let chrome = NSView(frame: window.contentView!.bounds)
        chrome.addSubview(first.contentView)
        window.contentView!.addSubview(chrome)
        return (first, second, chrome, window)
    }

    @Test func aParkedTabNeedsTheRenderWindow() {
        let (first, _, chrome, window) = rig()
        defer { window.close() }
        #expect(first.host.visibleTab === first)
        #expect(!first.agentRelay.needsRenderWindow, "a shown tab draws in its pane")
        chrome.isHidden = true
        #expect(first.host.visibleTab == nil, "a parked tab is not the host's shown tab")
        #expect(first.agentRelay.needsRenderWindow, "a parked tab an agent drives renders off screen")
    }

    @Test func aParkedTabBesideAShownTabOfItsWindowStays() {
        let (first, second, chrome, window) = rig()
        defer { window.close() }
        chrome.isHidden = true
        window.contentView!.addSubview(second.contentView)
        #expect(first.host.visibleTab === second)
        #expect(!first.agentRelay.needsRenderWindow, "moving it would take the window from the pane")
    }
}
