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

    /// Toolbar buttons scale Default's 29 pt square and keep the tab's hover shape.
    @Test(arguments: DensityPreset.allCases)
    func toolbarButtonsScaleDefaultsSquareAndHover(preset: DensityPreset) {
        DensityTokens.$scoped.withValue(preset.tokens) {
            let window = window(CGSize(width: 1000, height: 600))
            defer { window.close() }
            let chrome = chrome(in: window)
            let reload = chrome.reloadButton.convert(chrome.reloadButton.bounds, to: nil)
            let row = (29 * CGFloat(preset.scaleFactor) * 2).rounded() / 2
            #expect(reload.width == row && reload.height == row, "the reload button is \(reload.size), the bar \(row)")
            // The hover corner is the buttons' one corner, a tab's (`Metrics.buttonCornerRadius`), and the glyph's ink a
            // point under the small icon (Helium's 13 pt at Default; Lucas 2026-11-13).
            // Lucas 2026-11-15: the tab's ratio on the button's own side, one shape at every density.
            #expect(chrome.reloadButton.layer?.cornerRadius == Metrics.buttonCornerRadius(proportionalTo: row),
                    "hover corner \(String(describing: chrome.reloadButton.layer?.cornerRadius))")
            #expect(abs(OmnibarStyle.toolbarIconSize * DensityTokens.toolbarGlyphInkRatio
                - Metrics.tokens.toolbarGlyphSize * DensityTokens.toolbarGlyphInkRatio) < 0.001)
        }
    }

    /// The gap is Default's 3 pt scaled to the nearest Retina pixel.
    @Test(arguments: DensityPreset.allCases)
    func toolbarButtonsScaleDefaultsThreePointGap(preset: DensityPreset) {
        DensityTokens.$scoped.withValue(preset.tokens) {
            let window = window(CGSize(width: 1000, height: 600))
            defer { window.close() }
            let chrome = chrome(in: window)
            let back = chrome.backButton.convert(chrome.backButton.bounds, to: nil)
            let forward = chrome.forwardButton.convert(chrome.forwardButton.bounds, to: nil)
            let reload = chrome.reloadButton.convert(chrome.reloadButton.bounds, to: nil)
            #expect(!chrome.forwardButton.isHidden)
            let gap = (3 * CGFloat(preset.scaleFactor) * 2).rounded() / 2
            #expect(OmnibarStyle.buttonSpacing == gap)
            #expect(abs(forward.minX - back.maxX - gap) <= 0.01, "back to forward \(forward.minX - back.maxX)")
            #expect(abs(reload.minX - forward.maxX - gap) <= 0.01, "forward to reload \(reload.minX - forward.maxX)")
        }
    }

    /// layout-constants.patch: `kLocationBarTrailingIconSize` 18 (Chrome 20),
    /// `kLocationBarMargin` 6 (twice the base padding). The bar is the chrome row (in place of
    /// `kLocationBarHeight` 28), with the chip's corner proportional to its own side.
    @Test func omnibarKeepsHeliumsLocationBarMetrics() {
        DensityTokens.$scoped.withValue(DensityPreset.cozy.tokens) {
            // 18 pt, or what a short bar leaves (Compact's 20 pt bar: 14).
            #expect(OmnibarStyle.trailingIconSize == Metrics.densityToken("omnibarTrailingIconSize"))
            // Helium's `kLocationBarHeight` (28 at Default; Lucas 2026-11-14), else a tab's height.
            #expect(OmnibarStyle.barHeight == (Metrics.densityToken("omnibarHeight") ?? Metrics.tabHeight))
            #expect(OmnibarStyle.chipButtonCornerRadius == (OmnibarStyle.chipSize * 8 / 28 * 2).rounded() / 2)
            #expect(OmnibarStyle.barMargin == 2 * OmnibarStyle.buttonSpacing)
            #expect(OmnibarStyle.buttonSpacing == 3)
        }
    }

    /// tabs.patch: `kMinimumContentsWidthForCloseButtons` 56 (Chromium 68). A selected tab with 60 pt
    /// of contents is roomy, so at rest it hides its x (cmux shows the x on hover, nxdog9).
    @Test func tabsTakeHeliumsCloseButtonThreshold() {
        DensityTokens.$scoped.withValue(DensityPreset.cozy.tokens) {
            let metrics = TabStripMetrics.standard
            #expect(metrics.closeMinContentsWidth == 56)
            let width = metrics.contentLeadingInset + metrics.contentTrailingInset + 60
            let rest = TabChromeVisibility.resolve(width: width, isPinned: false, isSelected: true, isHovered: false, style: .chrome, metrics: metrics)
            #expect(!rest.showsClose, "a selected tab with 60 pt of contents shows its x at rest")
        }
    }

    /// tabs.patch (tab_close_button.cc): the x's hover is a rounded rect, not Chrome's circle, with Helium's own 4 pt
    /// corner on its 14 pt square (`RoundRectHighlightPathGenerator`), not one nested in the pill (Lawrence 2026-11-13:
    /// "need to match the X icon on helium in terms of hover too (like roundness of it), should be applied to all
    /// densities"; `HeliumTabCloseButtonTests` checks every density).
    @Test func tabCloseHoverIsHeliumsRoundedSquare() {
        DensityTokens.$scoped.withValue(DensityPreset.cozy.tokens) {
            let metrics = TabStripMetrics.standard
            #expect(metrics.closeCornerRadius == (metrics.closeButtonSize * 4 / 14 * 2).rounded() / 2)
            #expect(metrics.closeCornerRadius < metrics.closeButtonSize / 2, "a rounded square, not a circle")
        }
    }
}
