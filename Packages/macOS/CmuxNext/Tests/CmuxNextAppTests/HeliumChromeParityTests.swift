import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// The browser chrome takes Helium's sizes, spacing and hover shapes, not Chrome's (Lawrence
/// 2026-10-20: "I actually wanted to match Helium not Chrome ... size, spacing, and the hover
/// effects"). Each number cites the Helium patch it comes from; plans/cmux-next/helium-parity.md
/// has the full table. Colors stay cmux's own.
@MainActor @Suite(.serialized, .closesItsWindows) struct HeliumChromeParityTests {
    private func window(_ size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func chrome(in window: NSWindow) -> BrowserChromeView {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        return chrome
    }

    /// layout-constants.patch: `kToolbarButtonHeight` 28 (Chrome 34), `TOOLBAR_BUTTON` insets 4,
    /// so the 20 pt icon fills a 28 pt square. toolbar.patch: the hover shape is a rounded square,
    /// `Emphasis::kHigh` (8), not Chrome's circle (`kMaximum`).
    @Test func toolbarButtonsAreHeliumsSquareWithAnEightPointHover() {
        let window = window(CGSize(width: 1000, height: 600))
        defer { window.close() }
        let chrome = chrome(in: window)
        let reload = chrome.reloadButton.convert(chrome.reloadButton.bounds, to: nil)
        #expect(reload.width == 28 && reload.height == 28, "the reload button is \(reload.size)")
        #expect(chrome.reloadButton.layer?.cornerRadius == 8, "hover corner \(String(describing: chrome.reloadButton.layer?.cornerRadius))")
        #expect(OmnibarStyle.toolbarIconSize == 20)
    }

    /// layout-constants.patch: `kToolbarElementPadding` and `kToolbarIconDefaultMargin` are the
    /// base padding, 3; the toolbar's FlexLayout collapses margins, so neighbors sit 3 pt apart.
    @Test func toolbarButtonsSitThreePointsApart() {
        let window = window(CGSize(width: 1000, height: 600))
        defer { window.close() }
        let chrome = chrome(in: window)
        let back = chrome.backButton.convert(chrome.backButton.bounds, to: nil)
        let forward = chrome.forwardButton.convert(chrome.forwardButton.bounds, to: nil)
        let reload = chrome.reloadButton.convert(chrome.reloadButton.bounds, to: nil)
        #expect(!chrome.forwardButton.isHidden)
        #expect(abs(forward.minX - back.maxX - 3) <= 0.01, "back to forward \(forward.minX - back.maxX)")
        #expect(abs(reload.minX - forward.maxX - 3) <= 0.01, "forward to reload \(reload.minX - forward.maxX)")
    }

    /// layout-constants.patch: `kLocationBarTrailingIconSize` 18 (Chrome 20), `kLocationBarHeight`
    /// 28, `kLocationBarChildCornerRadius` 6, `kLocationBarMargin` 6 (twice the base padding).
    @Test func omnibarKeepsHeliumsLocationBarMetrics() {
        #expect(OmnibarStyle.trailingIconSize == 18)
        #expect(OmnibarStyle.barHeight == 28)
        #expect(OmnibarStyle.chipCornerRadius == 6)
        #expect(OmnibarStyle.barMargin == 6)
        #expect(OmnibarStyle.buttonSpacing == 3)
    }

    /// tabs.patch: `kMinimumContentsWidthForCloseButtons` 56 (Chromium 68). A selected tab with 60 pt
    /// of contents is roomy, so at rest it hides its x (cmux shows the x on hover, nxdog9).
    @Test func tabsTakeHeliumsCloseButtonThreshold() {
        let metrics = TabStripMetrics.standard
        #expect(metrics.closeMinContentsWidth == 56)
        let width = metrics.contentLeadingInset + metrics.contentTrailingInset + 60
        let rest = TabChromeVisibility.resolve(width: width, isPinned: false, isSelected: true, isHovered: false, style: .chrome, metrics: metrics)
        #expect(!rest.showsClose, "a selected tab with 60 pt of contents shows its x at rest")
    }

    /// tabs.patch (tab_close_button.cc): the x's hover is a rounded rect, `kCornerRadius` 4, not
    /// Chrome's circle.
    @Test func tabCloseHoverIsAFourPointRoundedRect() {
        #expect(TabStripMetrics.standard.closeCornerRadius == 4)
    }
}
