import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// One vertical gap runs through a pane's chrome in every window style (Lawrence 2026-10-19, on
/// Panes and Floating Panes: "between the tab and the omnibar and between the tab and the pane,
/// the top needs to be identical"; and "the space above the browser omnibar row must equal the
/// space below it"). The gap is `PaneChromeMetrics.tabGap`, and it is measured from what the eye
/// sees as the edge:
///
/// - above the tab pills: from the pane's visible top edge (the cell's top, or under Floating
///   Panes the pane card's own top edge, which sits the pane padding inside the cell);
/// - below the pills: to the strip's bottom (the content border);
/// - above the omnibar: from the tab pills' bottom, or from the pane outline's top line where the
///   style outlines each pane (Panes, Card Outlined), so the bar never sits on that line;
/// - below the omnibar: to the page.
///
/// The tab strip is the same view over terminal, Markdown and browser content, so its gaps hold
/// for every tab kind; the omnibar row is the browser's.
@MainActor @Suite(.serialized, .closesItsWindows) struct PaneChromeEvenGapTests {
    /// Applies `style` the way a settings load does, with nothing else set.
    private func load(_ style: ChromeStyle?) {
        let appearance: JSONValue = style.map { .object(["chromeStyle": .string($0.rawValue)]) } ?? .object([:])
        let snapshot = CmuxConfigSnapshot.parse(.object(["appearance": appearance]), validDensities: SettingsApplier.validDensities,
                                                validMetrics: SettingsApplier.validMetrics)
        _ = SettingsApplier(registry: ActionRegistry.standard()).apply(snapshot)
    }

    private func window(_ size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// `rect` (in `view`) as window points with a top-left origin.
    private func topLeft(_ rect: CGRect, in view: NSView, window: NSWindow) -> CGRect {
        let inWindow = view.convert(rect, to: nil)
        let height = window.contentView?.bounds.height ?? window.frame.height
        return CGRect(x: inWindow.minX, y: height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
    }

    @Test(arguments: ChromeStyle.allCases)
    func theTabPillsSitOnOneGapBelowThePanesVisibleTopEdge(style: ChromeStyle) throws {
        defer { load(nil) }
        load(style)
        let model = TabStripModel(tabs: (0..<2).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }, selectedID: TabID("tab0"))
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        let window = window(CGSize(width: 700, height: 200))
        defer { window.close() }
        let scale = window.backingScaleFactor
        let gap = PaneChromeMetrics.current.tabGap(scale: scale)
        let stripHeight = PaneChromeMetrics.current.resolvedStripHeight(scale: scale)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 200))
        window.contentView = host
        // The pane cell's top is the host's top; the strip starts where the pane lays it: the pane
        // padding inside the cell (the content rect, `PaneChromeGeometry.contentRect`).
        let padding = Metrics.panePadding
        strip.frame = NSRect(x: padding, y: 200 - padding - stripHeight, width: 700 - 2 * padding, height: stripHeight)
        host.addSubview(strip)
        strip.layoutSubtreeIfNeeded()
        let pill = topLeft(try #require(strip.firstTabPillFrame), in: strip, window: window)
        let stripRect = topLeft(strip.bounds, in: strip, window: window)
        // Floating Panes draw each pane as one card from the content rect's top; elsewhere nothing
        // is drawn above the strip, so the cell's top is the edge.
        let visibleTop = Metrics.floatingPanes ? stripRect.minY : 0
        let above = pill.minY - visibleTop, below = stripRect.maxY - pill.maxY
        #expect(abs(above - gap) <= 0.5, "\(style): \(above) pt above the pills, the gap is \(gap)")
        #expect(abs(below - gap) <= 0.5, "\(style): \(below) pt below the pills, the gap is \(gap)")
        #expect(abs(above - below) <= 0.5, "\(style): \(above) pt above the pills, \(below) pt below")
    }

    @Test(arguments: ChromeStyle.allCases)
    func theOmnibarRowHasTheSameGapAboveAndBelow(style: ChromeStyle) throws {
        defer { load(nil) }
        load(style)
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let window = window(CGSize(width: 1000, height: 600))
        defer { window.close() }
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        let gap = PaneChromeMetrics.current.tabGap(scale: window.backingScaleFactor)
        let top = topLeft(chrome.bounds, in: chrome, window: window).minY
        let bar = topLeft(chrome.addressBar.bounds, in: chrome.addressBar, window: window)
        let page = topLeft(chrome.contentContainer.bounds, in: chrome.contentContainer, window: window)
        // The chrome's top is the strip's bottom. An outlined pane draws its outline's top line
        // there, and that line is the edge above the bar; without one the edge is the tab pills'
        // bottom, one gap above the strip's bottom.
        // The row's content is the taller of the bar and the toolbar buttons; the bar is centered
        // in it, so its space above equals its space below.
        let inset = (max(chrome.addressBar.bounds.height, chrome.reloadButton.bounds.height) - chrome.addressBar.bounds.height) / 2
        let above = Metrics.paneBorder == .subtle ? bar.minY - top - (Metrics.paneBorderWidth ?? 1 / window.backingScaleFactor) : bar.minY - top + gap
        let below = page.minY - bar.maxY
        #expect(abs(above - (gap + inset)) <= 0.5, "\(style): \(above) pt above the omnibar, the gap is \(gap) + \(inset)")
        #expect(abs(below - (gap + inset)) <= 0.5, "\(style): \(below) pt below the omnibar, the gap is \(gap) + \(inset)")
        #expect(abs(above - below) <= 0.5, "\(style): \(above) pt above the omnibar, \(below) pt below")
    }

    /// The toolbar buttons are Helium's size (`kToolbarButtonHeight` 28, a 20 pt icon in an 8 pt
    /// rounded-square highlight; Lawrence 2026-10-20 "match Helium not Chrome"), the omnibar's own
    /// height. The row's one gap runs from the tallest thing in it: the same above the buttons as
    /// below them, and the omnibar sits on their center line.
    @Test(arguments: ChromeStyle.allCases)
    func theToolbarButtonsAreHeliumsSizeAndKeepTheRowsEvenGap(style: ChromeStyle) throws {
        defer { load(nil) }
        load(style)
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let window = window(CGSize(width: 1000, height: 600))
        defer { window.close() }
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        let gap = PaneChromeMetrics.current.tabGap(scale: window.backingScaleFactor)
        let top = topLeft(chrome.bounds, in: chrome, window: window).minY
        let reload = topLeft(chrome.reloadButton.bounds, in: chrome.reloadButton, window: window)
        let bar = topLeft(chrome.addressBar.bounds, in: chrome.addressBar, window: window)
        let page = topLeft(chrome.contentContainer.bounds, in: chrome.contentContainer, window: window)
        #expect(reload.width == 28 && reload.height == 28, "\(style): the reload button is \(reload.size)")
        #expect(abs(reload.midY - bar.midY) <= 0.5, "\(style): the omnibar's center is \(bar.midY), the buttons' \(reload.midY)")
        let above = Metrics.paneBorder == .subtle ? reload.minY - top - (Metrics.paneBorderWidth ?? 1 / window.backingScaleFactor) : reload.minY - top + gap
        let below = page.minY - reload.maxY
        #expect(abs(above - gap) <= 0.5, "\(style): \(above) pt above the buttons, the gap is \(gap)")
        #expect(abs(below - gap) <= 0.5, "\(style): \(below) pt below the buttons, the gap is \(gap)")
    }
}
