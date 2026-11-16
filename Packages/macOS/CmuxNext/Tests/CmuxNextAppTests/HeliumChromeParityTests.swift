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

    /// The buttons are the window's one chrome row (a sidebar row, a tab pill: Lawrence 2026-11-09,
    /// in place of Helium's `kToolbarButtonHeight` 28), and the glyph's ink is a tab icon's side.
    /// toolbar.patch: the hover shape is a rounded square, not Chrome's circle (`kMaximum`). Its corner is
    /// the tab's (Lawrence 2026-11-12: "roundness of all buttons should match roundness of tabs/workspaces"),
    /// Helium's `Emphasis::kHigh` 8 at Default, 6 at a compact row.
    @Test func toolbarButtonsAreHeliumsSquareWithATabCornerHover() {
        let window = window(CGSize(width: 1000, height: 600))
        defer { window.close() }
        let chrome = chrome(in: window)
        let reload = chrome.reloadButton.convert(chrome.reloadButton.bounds, to: nil)
        let row = Metrics.chromeRowHeight
        #expect(reload.width == row && reload.height == row, "the reload button is \(reload.size), the row \(row)")
        // The hover corner is the buttons' one corner, a tab's (`Metrics.buttonCornerRadius`), and the glyph's ink a
        // point under the small icon (Helium's 13 pt at Default; Lucas 2026-11-13).
        #expect(chrome.reloadButton.layer?.cornerRadius == Metrics.tabCornerRadius, "hover corner \(String(describing: chrome.reloadButton.layer?.cornerRadius))")
        #expect(abs(OmnibarStyle.toolbarIconSize * DensityTokens.toolbarGlyphInkRatio
            - DensityTokens.toolbarGlyphInk(smallIcon: Metrics.smallIconSize)) < 0.001)
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

    /// layout-constants.patch: `kLocationBarTrailingIconSize` 18 (Chrome 20),
    /// `kLocationBarMargin` 6 (twice the base padding). The bar is the chrome row (in place of
    /// `kLocationBarHeight` 28), rounded as Chrome rounds its tab (Lawrence 2026-11-11), so the chip
    /// nests in it: the bar's radius less its 2 pt inset, in place of `kLocationBarChildCornerRadius` 6.
    @Test func omnibarKeepsHeliumsLocationBarMetrics() {
        // 18 pt, or what a short bar leaves (Compact's 20 pt bar: 14).
        #expect(OmnibarStyle.trailingIconSize == min(18, OmnibarStyle.barHeight - 6))
        #expect(OmnibarStyle.barHeight == Metrics.chromeRowHeight)
        #expect(OmnibarStyle.chipButtonCornerRadius == max(0, OmnibarStyle.cardCornerRadius - OmnibarStyle.chipLeading))
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

    /// tabs.patch (tab_close_button.cc): the x's hover is a rounded rect, not Chrome's circle, with Helium's own 4 pt
    /// corner on its 14 pt square (`RoundRectHighlightPathGenerator`), not one nested in the pill (Lawrence 2026-11-13:
    /// "need to match the X icon on helium in terms of hover too (like roundness of it), should be applied to all
    /// densities"; `HeliumTabCloseButtonTests` checks every density).
    @Test func tabCloseHoverIsHeliumsRoundedSquare() {
        let metrics = TabStripMetrics.standard
        #expect(metrics.closeCornerRadius == (metrics.closeButtonSize * 4 / 14 * 2).rounded() / 2)
        #expect(metrics.closeCornerRadius < metrics.closeButtonSize / 2, "a rounded square, not a circle")
    }
}
