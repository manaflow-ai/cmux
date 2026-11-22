import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextTabs
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextTestSupport
import Testing

/// Lucas 2026-11-15: the omnibar's editing ring draws outside the bar, whole, while the bar sits one tab gap under the
/// tabs (the gap from the tab to the bar is the gap above the tab). The pane's content area clips at the toolbar's
/// top edge, so the ring lives in the pane's own layer above that clip: a real pane (a container, its clipping
/// content area, the browser chrome in it) is laid out, the bar starts editing, and the ring must be in the pane's
/// layer, one ring width outside the bar on every side, with the bar flush at the toolbar's top.
@MainActor @Suite(.serialized, .closesItsWindows) struct OmnibarRingAboveClipTests {
    @Test(arguments: [DensityPreset.compact, .cozy, .comfortable, .spacious])
    func theRingIsWholeAboveTheContentClip(preset: DensityPreset) throws {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        _ = NSApplication.shared
        let size = NSSize(width: 900, height: 500)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        window.contentView = root
        // A pane is flipped (PaneContentView), its content area under its strip.
        let pane = FlippedRingTestPane(frame: root.bounds)
        pane.wantsLayer = true
        pane.autoresizingMask = [.width, .height]
        root.addSubview(pane)
        let area = PaneContentAreaView(frame: NSRect(x: 0, y: 40, width: size.width, height: size.height - 40))
        area.autoresizingMask = [.width, .height]
        pane.addSubview(area)
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = area.bounds
        chrome.autoresizingMask = [.width, .height]
        area.addSubview(chrome)
        root.layoutSubtreeIfNeeded()
        let bar = chrome.addressBar
        bar.pill.state = .editing
        root.layoutSubtreeIfNeeded()
        bar.pill.layoutSubtreeIfNeeded()

        let width = Metrics.lineWidth(OmnibarStyle.ringWidth)
        // The ring stays on the bar after a vertical resize, which runs no layout of the bar's own (no window observer).
        for height in [size.height, size.height + 160] {
            window.setContentSize(NSSize(width: size.width, height: height))
            root.layoutSubtreeIfNeeded()
            let ring = bar.pill.debugRing
            #expect(ring.host === pane.layer, "\(preset): the ring is in \(String(describing: ring.host)), not the pane's layer")
            // The ring's layer frame is in the pane's (flipped) points: its layer shares its coordinates.
            let barInPane = pane.convert(bar.bounds, from: bar)
            let expected = barInPane.insetBy(dx: -width, dy: -width)
            #expect(abs(ring.frame.minX - expected.minX) <= 0.01 && abs(ring.frame.maxX - expected.maxX) <= 0.01
                    && abs(ring.frame.minY - expected.minY) <= 0.01 && abs(ring.frame.maxY - expected.maxY) <= 0.01,
                    "\(preset) at \(height): the ring is \(ring.frame), the bar \(barInPane)")
        }
        let barInWindow = bar.convert(bar.bounds, to: nil)
        // The bar starts at the toolbar's top edge: the tab gap above it is the strip's, as above the tabs.
        let areaTop = area.convert(area.bounds, to: nil).maxY
        #expect(abs(barInWindow.maxY - areaTop) <= 0.01, "\(preset): the bar's top is \(barInWindow.maxY), the toolbar's \(areaTop)")
        #expect(bar.pill.debugStyle["ring_width"] as? Double == Double(width))
    }

    /// A toolbar at the pane's bottom puts the bar on the content area's bottom edge (a borderless pane): the ring draws
    /// inside the bar there, whole, since that edge moves with a vertical resize that runs no layout of the bar's own.
    @Test(arguments: [DensityPreset.compact, .cozy, .comfortable, .spacious])
    func aBarOnTheBottomEdgeKeepsItsRingWhole(preset: DensityPreset) throws {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        _ = NSApplication.shared
        let size = NSSize(width: 900, height: 500)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        window.contentView = root
        let pane = FlippedRingTestPane(frame: root.bounds)
        pane.wantsLayer = true
        pane.autoresizingMask = [.width, .height]
        root.addSubview(pane)
        let area = PaneContentAreaView(frame: NSRect(x: 0, y: 40, width: size.width, height: size.height - 40))
        area.autoresizingMask = [.width, .height]
        pane.addSubview(area)
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = area.bounds
        chrome.autoresizingMask = [.width, .height]
        chrome.toolbarPosition = .bottom
        area.addSubview(chrome)
        root.layoutSubtreeIfNeeded()
        let bar = chrome.addressBar
        bar.pill.state = .editing
        root.layoutSubtreeIfNeeded()
        bar.pill.layoutSubtreeIfNeeded()

        let ring = bar.pill.debugRing
        let hostView: NSView = ring.host === pane.layer ? pane : bar.pill
        let ringInArea = area.convert(ring.frame, from: hostView)
        #expect(ring.host !== pane.layer, "\(preset): a bottom bar's ring is in the pane's layer, which a vertical resize leaves behind")
        #expect(ringInArea.minX >= area.bounds.minX - 0.01 && ringInArea.maxX <= area.bounds.maxX + 0.01
                && ringInArea.minY >= area.bounds.minY - 0.01 && ringInArea.maxY <= area.bounds.maxY + 0.01,
                "\(preset): the ring \(ringInArea) leaves the content area \(area.bounds), which clips it")
        #expect(bar.pill.debugStyle["ring_width"] as? Double == Double(Metrics.lineWidth(OmnibarStyle.ringWidth)))
    }
}

/// Lucas 2026-11-15: one gap above the tabs, between the tabs and the omnibar, and between the omnibar and the page,
/// at every density, in a lower pane's strip and in the window's top row. Default's omnibar row is Chrome's 6 pt above
/// and below the bar (Lucas 2026-11-20).
@MainActor @Suite(.serialized, .closesItsWindows) struct BrowserChromeOneGapTests {
    @Test(arguments: [DensityPreset.ultraCompact, .compact, .cozy, .comfortable, .spacious], [false, true])
    func oneGapAboveBetweenAndUnderTheRows(preset: DensityPreset, topRow: Bool) throws {
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.tabBarPosition, design.titlebar)
        defer { (design.densityTokens, design.tabBarPosition, design.titlebar) = saved }
        design.densityTokens = preset.tokens
        design.tabBarPosition = .top
        design.titlebar = .minimal
        _ = NSApplication.shared
        let style: NSWindow.StyleMask = topRow ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: style, backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let size = window.contentView?.bounds.size ?? NSSize(width: 1000, height: 600)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        window.contentView = root
        let stripHeight = PaneChromeMetrics.current.resolvedStripHeight(scale: window.backingScaleFactor)
        let strip = TabStripView(model: TabStripModel(tabs: (0..<2).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") },
                                                      selectedID: TabID("t1")))
        strip.frame = NSRect(x: 0, y: size.height - stripHeight, width: size.width, height: stripHeight)
        root.addSubview(strip)
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let chrome = BrowserChromeView(tab: tab)
        chrome.meetsTabStrip = true // the strip sits right above the toolbar, as the pane says
        chrome.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - stripHeight)
        root.addSubview(chrome)
        root.layoutSubtreeIfNeeded()
        strip.layoutSubtreeIfNeeded()
        chrome.layoutSubtreeIfNeeded()

        let pill = strip.convert(try #require(strip.firstTabPillFrame), to: nil)
        let bar = chrome.addressBar.convert(chrome.addressBar.bounds, to: nil)
        let page = chrome.contentContainer.convert(chrome.contentContainer.bounds, to: nil)
        // Above the tab: from the strip's top in a lower pane, from under the window's lit rim in the top row (Lucas 2026-11-17).
        let top = topRow ? size.height - WindowTitlebar.topRowRim(in: window) : strip.convert(strip.bounds, to: nil).maxY
        let above = top - pill.maxY, between = pill.minY - bar.maxY, under = bar.minY - page.maxY
        let at = "\(preset.rawValue) top row \(topRow)"
        // Compact's tabs sit 1 pt further from the bar than its strip padding (`tabToOmnibarGap`, Lucas 2026-11-20).
        let tokens = preset.tokens.tokens
        let extra = CGFloat(tokens["tabToOmnibarGap"].map { max(0, $0 - (tokens["browserRowGap"] ?? $0)) } ?? 0)
        // One pixel: a 1x screen snaps Compact's 2.5 and 3.5 pt gaps to whole points.
        let pixel = max(0.5, 1 / window.backingScaleFactor)
        #expect(abs(between - extra - under) <= pixel, "\(at): \(between) pt from the tab to the omnibar, \(under) pt from the omnibar to the page")
        // Default is Chrome's: 5 pt above the tab, 6 pt from it to the omnibar and from the omnibar to the page; Comfortable
        // and Spacious are that times 1.1 and 1.2 on the half-point grid (Lucas 2026-11-20), Spacious a half point more
        // for its half-point bar (Lucas 2026-11-21).
        let chromeGaps: [DensityPreset: (above: CGFloat, between: CGFloat)] = [.cozy: (5, 6), .comfortable: (5.5, 6.5), .spacious: (6.5, 7.5)]
        if let want = chromeGaps[preset] {
            #expect(abs(above - want.above) <= 0.5, "\(at): \(above) pt above the tab, want \(want.above)")
            #expect(abs(between - want.between) <= 0.5, "\(at): \(between) pt from the tab to the omnibar, want \(want.between)")
        } else {
            #expect(abs(above + extra - between) <= pixel, "\(at): \(above) pt above the tab, \(between) pt from the tab to the omnibar")
        }
    }
}

/// A pane as the app makes it (PaneContentView): flipped.
private final class FlippedRingTestPane: NSView {
    override var isFlipped: Bool { true }
}
