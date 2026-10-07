import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextBrowser

/// Serialized: the tests mutate the shared `DesignSettings`.
@Suite(.serialized) struct DensityTests {
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @Test func toolbarFollowsLiveDensityChanges() async {
        let settings = DesignSettings.shared
        let original = settings.density
        defer { settings.density = original }
        settings.density = .compact

        let binding = DensityBinding()
        let view = NSView()
        let height = binding.bind(view.heightAnchor.constraint(equalToConstant: 0)) { BrowserMetrics.toolbarHeight }
        binding.start()
        #expect(height.constant == Metrics.tabStripHeight)
        let compact = height.constant

        settings.density = .comfortable
        await settle()
        #expect(height.constant == Metrics.tabStripHeight)
        #expect(height.constant > compact)
    }

    @Test func toolbarUsesOmnibarGeometry() async {
        let settings = DesignSettings.shared
        defer { settings.setOverride(.tabStripHeight, nil) }

        let chrome = BrowserChromeView(tab: MockBrowserEngine().makeMockTab(BrowserTabConfiguration()))
        chrome.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        chrome.layoutSubtreeIfNeeded()
        let toolbar = chrome.subviews.first { $0.subviews.contains(chrome.addressBar) }
        // Omnibar geometry: the bar, then the chrome gap down to the page
        // (R101), whatever the tab strip override (the omnibar has its own
        // size, not a tab's).
        #expect(toolbar?.frame.height == chrome.currentToolbarHeight)
        #expect(chrome.addressBar.frame.height == OmnibarStyle.barHeight)
        #expect(chrome.currentToolbarHeight == OmnibarStyle.barHeight + OmnibarStyle.chromeGap(scale: NSScreen.main?.backingScaleFactor ?? 2))

        settings.setOverride(.tabStripHeight, 40)
        await settle()
        chrome.layoutSubtreeIfNeeded()
        #expect(toolbar?.frame.height == chrome.currentToolbarHeight)
    }
}
