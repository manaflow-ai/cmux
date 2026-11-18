import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextIcons
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// The window's rows are one height, and the browser's back arrow starts where the first tab's icon
/// does (Lawrence 2026-11-09: "we need proper left alignment of back arrow and the first icon of the
/// first tab. also the sizes of the icons/omnibar etc should match the tabbar tab height, which
/// should match the workspace row height, at all density levels").
///
/// Real tab strips and browser chrome keep that alignment at every preset and `sidebar.density`.
/// Tabs follow the visible workspace row; the omnibar and its buttons scale Default's 29 pt reference,
/// and the toolbar glyphs scale the Compact Helium calibration independently of the row-height exceptions.
@MainActor @Suite(.serialized, .closesItsWindows) struct ChromeRowHeightTests {
    private func load(_ preset: DensityPreset, _ sidebar: SidebarDensity) {
        DesignSettings.shared.densityTokens = preset.tokens
        DesignSettings.shared.sidebarSections.density = sidebar
    }

    private func reset() { load(.compact, .compact) }

    /// A pane's tab strip as `PaneContentView` lays it out (x 0, the resolved strip height), its first
    /// tab drawing the pack's terminal icon, which fills the tab's icon box.
    private func strip() -> (NSWindow, TabStripView) {
        _ = NSApplication.shared
        let items = (0..<2).map { TabItem(id: TabID("tab\($0)"), title: "lawrence@cmux \($0)", icon: .icon(.tabTerminal)) }
        // The second tab is selected: a selected tab runs down into the page card, so the first is a plain pill.
        let strip = TabStripView(model: TabStripModel(tabs: items, selectedID: TabID("tab1")))
        strip.dragsWindowFromEmptySpace = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = FlippedView(frame: NSRect(x: 0, y: 0, width: 700, height: 120))
        host.wantsLayer = true
        window.contentView = host
        strip.frame = NSRect(x: 0, y: 0, width: 700, height: PaneChromeMetrics.current.resolvedStripHeight(scale: window.backingScaleFactor))
        host.addSubview(strip)
        host.layoutSubtreeIfNeeded()
        strip.layoutSubtreeIfNeeded()
        return (window, strip)
    }

    private func chrome() -> (NSWindow, BrowserChromeView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        return (window, chrome)
    }

    /// The horizontal extent of a bitmap's ink (alpha over 1/4), in points.
    private func inkSpan(_ rep: NSBitmapImageRep, pointWidth: CGFloat) -> ClosedRange<CGFloat>? {
        let scale = CGFloat(rep.pixelsWide) / max(pointWidth, 1)
        var columns: [Int] = []
        for x in 0..<rep.pixelsWide where (0..<rep.pixelsHigh).contains(where: { (rep.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.25 }) {
            columns.append(x)
        }
        guard let first = columns.first, let last = columns.last else { return nil }
        return CGFloat(first) / scale...CGFloat(last + 1) / scale
    }

    /// Where `image` draws ink across its width, rendered at 2x.
    private func inkSpan(_ image: NSImage) -> ClosedRange<CGFloat>? {
        let size = image.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * 2).rounded(.up)), pixelsHigh: Int((size.height * 2).rounded(.up)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return inkSpan(rep, pointWidth: size.width)
    }

    /// Where `layer` draws ink across its own width, rendered at 2x.
    private func inkSpan(_ layer: CALayer) -> ClosedRange<CGFloat>? {
        let size = layer.bounds.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
        context.scaleBy(x: 2, y: 2)
        layer.render(in: context)
        return inkSpan(rep, pointWidth: size.width)
    }

    /// Tabs follow the visible sidebar row, including sidebar settings. The omnibar and its buttons scale
    /// Default's separate 29 pt location bar, independent of the specified row-height exceptions.
    @Test(arguments: DensityPreset.allCases, SidebarDensity.allCases)
    func tabNavigationAndOmnibarTakeTheDensitysHeights(preset: DensityPreset, sidebar: SidebarDensity) throws {
        defer { reset() }
        load(preset, sidebar)
        let row = SidebarRowTokens.current.listRowHeight
        let (stripWindow, strip) = strip()
        defer { stripWindow.close() }
        let pill = try #require(strip.firstTabPillFrame)
        let (window, chrome) = chrome()
        defer { window.close() }
        let back = chrome.backButton.convert(chrome.backButton.bounds, to: nil)
        let bar = chrome.addressBar.convert(chrome.addressBar.bounds, to: nil)
        let omnibar = OmnibarMetrics.current.barHeight
        let label = "\(preset) / sidebar \(sidebar): row \(row), tab \(Metrics.tabHeight), omnibar \(omnibar)"
        #expect(abs(pill.height - Metrics.tabHeight) <= 0.5, "\(label), pill \(pill.height)")
        #expect(abs(back.height - omnibar) <= 0.5, "\(label), back button \(back.height)")
        #expect(abs(back.width - omnibar) <= 0.5, "\(label), back button is square: \(back.width)")
        #expect(abs(bar.height - omnibar) <= 0.5, "\(label), omnibar \(bar.height)")
        #expect(abs(pill.height - row) <= 0.5, "\(label): the tab follows the visible row")
        let expectedBar = (29 * CGFloat(preset.scaleFactor) * 2).rounded() / 2
        #expect(abs(bar.height - expectedBar) <= 0.5, "\(label): the bar scales Default's 29 pt reference")
    }

    @Test(arguments: DensityPreset.allCases)
    func backArrowStartsOnTheFirstTabIcon(preset: DensityPreset) throws {
        defer { reset() }
        load(preset, .compact)
        let (stripWindow, strip) = strip()
        defer { stripWindow.close() }
        let cell = try #require(strip.cells[TabID("tab0")])
        let cellLayer = try #require(cell.layer as CALayer?)
        let stripLayer = try #require(strip.layer)
        let iconFrame = cellLayer.convert(cell.iconLayer.frame, to: stripLayer)
        let iconInk = try #require(inkSpan(cell.iconLayer), "\(preset): the first tab's icon draws no ink")
        let (window, chrome) = chrome()
        defer { window.close() }
        let back = chrome.backButton
        // The button draws its glyph image centered in its square (`imagePosition = .imageOnly`).
        let glyph = try #require(back.image, "\(preset): the back button has no glyph")
        let arrowInk = try #require(inkSpan(glyph), "\(preset): the back arrow draws no ink")
        let glyphLeft = (back.bounds.width - glyph.size.width) / 2
        // Both rows start at their pane's leading edge (PaneContentView lays the strip and the
        // content host out from x 0), so the strip's and the chrome's own x are one column.
        let arrowLeft = back.convert(NSPoint(x: glyphLeft + arrowInk.lowerBound, y: 0), to: chrome).x
        // The icon's box, not one glyph's ink: favicons and agent marks fill the box, the pack's
        // terminal starts its chevron 2 pt in. The arrow's ink starts on the box every tab icon shares.
        let iconLeft = iconFrame.minX
        #expect(iconInk.lowerBound >= -0.01, "\(preset): the tab icon draws inside its box")
        // The arrow's ink starts on the icon box, or as near as the toolbar's leading edge lets it: a large density's
        // button is wider than its 13 pt ink, and the button stays inside the toolbar (OmnibarStyle.toolbarInset).
        #expect(arrowLeft >= iconLeft - 0.75, "\(preset): back arrow ink starts at \(arrowLeft), first tab icon box at \(iconLeft)")
        #expect(arrowLeft <= iconLeft + 0.75 || OmnibarStyle.toolbarInset == 0,
                "\(preset): back arrow ink starts at \(arrowLeft), first tab icon box at \(iconLeft)")
        // Compact's 14 pt reload ink calibrates the shared toolbar box (0.617 of its side); the back arrow's
        // keyline fills 0.6 of that box. Both scale from Default, independently of the small-icon fallback.
        let arrowWidth = arrowInk.upperBound - arrowInk.lowerBound
        let box = ((14 / 0.9 / 0.617) * CGFloat(preset.scaleFactor) * 2).rounded() / 2
        let ink = box * DensityTokens.toolbarGlyphInkRatio
        #expect(abs(arrowWidth - ink) <= 1, "\(preset): back arrow ink \(arrowWidth) wide, want \(ink)")
    }
}
