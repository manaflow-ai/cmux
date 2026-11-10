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
/// At every density preset and every `sidebar.density`, a real tab strip and a real browser chrome
/// are laid out in a window: the tab pill, the back button and the omnibar are each as tall as a
/// one-line sidebar workspace row (``SidebarRowTokens``), the back arrow's ink is the tab icon's
/// side, and its leftmost ink sits on the first tab icon's box (the box every tab icon shares). Base drew a 24 pt tab beside a 28 pt
/// omnibar and back button at Compact (30 / 34 / 32 at Comfortable), and the arrow's 12 pt ink
/// beside the tab's 14 pt icon.
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
        let strip = TabStripView(model: TabStripModel(tabs: items, selectedID: TabID("tab0")))
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

    @Test(arguments: DensityPreset.allCases, SidebarDensity.allCases)
    func tabNavigationAndOmnibarAreOneSidebarRowTall(preset: DensityPreset, sidebar: SidebarDensity) throws {
        defer { reset() }
        load(preset, sidebar)
        let row = SidebarRowTokens.current.rowHeight
        let (stripWindow, strip) = strip()
        defer { stripWindow.close() }
        let pill = try #require(strip.firstTabPillFrame)
        let (window, chrome) = chrome()
        defer { window.close() }
        let back = chrome.backButton.convert(chrome.backButton.bounds, to: nil)
        let bar = chrome.addressBar.convert(chrome.addressBar.bounds, to: nil)
        let label = "\(preset) / sidebar \(sidebar): row \(row)"
        #expect(abs(pill.height - row) <= 0.5, "\(label), tab \(pill.height)")
        #expect(abs(back.height - row) <= 0.5, "\(label), back button \(back.height)")
        #expect(abs(back.width - row) <= 0.5, "\(label), back button is square: \(back.width)")
        #expect(abs(bar.height - row) <= 0.5, "\(label), omnibar \(bar.height)")
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
        #expect(abs(arrowLeft - iconLeft) <= 0.75, "\(preset): back arrow ink starts at \(arrowLeft), first tab icon box at \(iconLeft)")
        // The arrow reads at the tab icon's size: its ink is the icon box's side.
        let arrowWidth = arrowInk.upperBound - arrowInk.lowerBound
        #expect(abs(arrowWidth - iconFrame.width) <= 1, "\(preset): back arrow ink \(arrowWidth) wide, tab icon box \(iconFrame.width)")
    }
}
