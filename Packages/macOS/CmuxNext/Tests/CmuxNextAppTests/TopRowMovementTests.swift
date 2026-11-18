import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// A pane that only moves in its window (a column or row scroll, a split, the sidebar's slide, a pane
/// coming to rest) skips its content's layout: the App tells its strip (`updateWindowControlsAvoidance`),
/// which re-checks the top row's line as well as the traffic lights (review of #37619). A top-row strip
/// moved down leaves the line for its own centering, and a lower strip moved up onto the top row takes
/// the line, with no resize; the pane's toolbar follows its strip both ways. On the top row the strip
/// sits where the card's top puts it, the pill keeps equal gaps (#38054) and the line is the pill's.
@MainActor @Suite(.closesItsWindows, .serialized) struct TopRowMovementTests {
    // Comfortable by default: its strip's own centering and the top row's differ, so a stale layout shows.
    // The lights' line (#38054): the card moves to bring the pills to it. The default line is now the
    // concentric one, whose card keeps the gutter (`WindowConcentricCornerTests`).
    func with(density: DensityPreset = .comfortable, _ body: () throws -> Void) rethrows {
        let design = DesignSettings.shared
        let before = (design.tabBarPosition, design.titlebar, design.densityTokens)
        design.tabBarPosition = .top
        design.titlebar = .minimal
        design.densityTokens = density.tokens
        TunableStore.shared.register(DesignTunables.all)
        TunableStore.shared.activate(file: nil)
        let key = TopRowLineLook.tunable.key, look = TunableStore.shared.override(key)
        TunableStore.shared.set(key, TopRowLineLook.lights.tunableValue)
        // These measure the tab pill's gaps; the flush corner (the default over this chrome) runs the
        // selected pill to the strip's bottom and has its own suites.
        MainPaneGutterSuites.pinsCornerFlushOff(true)
        defer {
            MainPaneGutterSuites.pinsCornerFlushOff(false)
            TunableStore.shared.set(key, look)
            (design.tabBarPosition, design.titlebar, design.densityTokens) = before
        }
        try body()
    }

    struct Fixture {
        let window: NSWindow
        let container: NSView
        let strip: TabStripView
        let toolbar: PaneToolbarView
    }

    func fixture(topRow: Bool) -> Fixture {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 640))
        window.contentView = container
        let tabs = [TabItem(id: TabID("a"), title: "A"), TabItem(id: TabID("b"), title: "B")]
        let strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: tabs[0].id))
        let height = Metrics.tabStripHeight
        let y = topRow ? container.bounds.maxY - height : 200
        strip.frame = NSRect(x: 240, y: y, width: 560, height: height)
        let toolbar = PaneToolbarView(frame: NSRect(x: 800, y: y, width: 120, height: height))
        container.addSubview(strip)
        container.addSubview(toolbar)
        toolbar.strip = strip
        container.layoutSubtreeIfNeeded()
        return Fixture(window: window, container: container, strip: strip, toolbar: toolbar)
    }

    /// Moves the strip and its toolbar by `dy` with no resize, tells the strip as the App does, then lays out.
    func move(_ f: Fixture, by dy: CGFloat) {
        f.strip.setFrameOrigin(NSPoint(x: f.strip.frame.minX, y: f.strip.frame.minY + dy))
        f.toolbar.setFrameOrigin(NSPoint(x: f.toolbar.frame.minX, y: f.toolbar.frame.minY + dy))
        f.strip.updateWindowControlsAvoidance()
        f.container.layoutSubtreeIfNeeded()
    }

    func pillTop(_ f: Fixture) throws -> CGFloat { try #require(f.strip.firstTabPillFrame).minY }
    func centered(_ f: Fixture) -> CGFloat { f.strip.metrics.tabTop(stripHeight: f.strip.bounds.height, scale: f.window.backingScaleFactor) }

    /// Where the main pane's card puts the top row's strips below the window's top edge
    /// (`WindowTitlebar.topRowCardTop`): the tabs reach the line from there with equal gaps.
    func cardTop(_ f: Fixture) throws -> CGFloat {
        let target = try #require(WindowTitlebar.targetTopRowLine(in: f.window))
        return WindowTitlebar.topRowCardTop(centeringPillOn: target.centerY, gutter: Metrics.mainPaneGutter, in: f.window)
    }

    /// The pill's center below the window's top edge.
    func pillCenterFromTop(_ f: Fixture) throws -> CGFloat {
        let pill = f.strip.convert(try #require(f.strip.firstTabPillFrame), to: nil)
        return f.container.bounds.maxY - pill.midY
    }

    @Test func aTopRowStripMovedDownLeavesTheLine() throws {
        try with {
            let f = fixture(topRow: true)
            defer { f.window.closeAfterTest() }
            move(f, by: -(try cardTop(f)))
            let line = try #require(WindowTitlebar.topRowLine(in: f.window))
            try #require(WindowTitlebar.isInTopRow(f.strip))
            #expect(abs(try pillCenterFromTop(f) - line.centerY) <= 0.5, "on the top row the pill centers on the line")
            let onLine = try pillTop(f)
            try #require(onLine != centered(f), "the line and the strip's own centering differ here")
            let buttonOnLine = f.toolbar.moreButton.frame.minY

            move(f, by: -300)
            #expect(!WindowTitlebar.isInTopRow(f.strip))
            #expect(try pillTop(f) == centered(f), "moved down, the pill keeps the strip's own centering, not the line's offset")
            #expect(f.toolbar.moreButton.frame.minY == PaneToolbarView.edgeInset(height: f.toolbar.bounds.height))
            #expect(f.toolbar.moreButton.frame.minY != buttonOnLine)
        }
    }

    /// #38054: a top-row pill keeps the gap above it (from the window's top edge, the row's top) equal
    /// to the gap below it (to the strip's bottom, the divider under the row), at every density, with
    /// the strip at the window's top or a few points under it (the card's top inset). Before, the pill
    /// moved inside its strip toward the traffic lights' line: Compact had 4 pt above and 0 below,
    /// Comfortable 1 above and 5 below.
    @Test func aTopRowPillHasEqualGapsAboveAndBelow() throws {
        for preset in [DensityPreset.ultraCompact, .compact, .cozy, .comfortable, .spacious] {
            try with(density: preset) {
                let f = fixture(topRow: true)
                defer { f.window.closeAfterTest() }
                var dropped: CGFloat = 0
                // Never past the room the pill leaves: the card's top stops there (`PaneChromeMetrics.cardTop`).
                for drop in [0, 1, 2, 4] as [CGFloat] where drop <= Metrics.tabStripHeight - Metrics.tabHeight {
                    move(f, by: dropped - drop)
                    dropped = drop
                    try #require(WindowTitlebar.isInTopRow(f.strip))
                    let pill = f.strip.convert(try #require(f.strip.firstTabPillFrame), to: nil)
                    let strip = f.strip.convert(f.strip.bounds, to: nil)
                    let above = f.container.bounds.maxY - pill.maxY, below = pill.minY - strip.minY
                    let pixel = 1 / f.window.backingScaleFactor
                    // Equal, or a device pixel apart where the room left is an odd number of pixels.
                    #expect(abs(above - below) <= pixel + 0.001, "\(preset) strip \(f.container.bounds.maxY - strip.maxY) pt down: \(above) above, \(below) below")
                    #expect(pill.maxY <= strip.maxY && pill.minY >= strip.minY, "\(preset): the pill stays inside its strip")
                }
            }
        }
    }

    /// Floating panes (review of #38079): each pane is its own card the gutter and a pane padding down, so
    /// its top-row pills keep their strip's own centering, and the line the controls read is their center.
    @Test func floatingPanesCenterTheirPillsInTheirOwnCards() throws {
        let design = DesignSettings.shared, style = design.chromeStyle
        design.chromeStyle = .floating
        defer { design.chromeStyle = style }
        try with(density: .compact) {
            let f = fixture(topRow: true)
            defer { f.window.closeAfterTest() }
            try #require(Metrics.floatingPanes)
            move(f, by: -(Metrics.mainPaneGutter + Metrics.panePadding))
            try #require(WindowTitlebar.isInTopRow(f.strip))
            #expect(try pillTop(f) == centered(f), "the pill keeps its strip's own centering in its card")
            let line = try #require(WindowTitlebar.topRowLine(in: f.window))
            #expect(abs(try pillCenterFromTop(f) - line.centerY) <= 0.5, "the controls' line is the pill's center")
        }
    }

    @Test func aLowerStripMovedUpTakesTheLine() throws {
        try with {
            let f = fixture(topRow: false)
            defer { f.window.closeAfterTest() }
            #expect(!WindowTitlebar.isInTopRow(f.strip))
            #expect(try pillTop(f) == centered(f))
            let buttonBelow = f.toolbar.moreButton.frame.minY

            move(f, by: f.container.bounds.maxY - (try cardTop(f)) - f.strip.frame.maxY)
            let line = try #require(WindowTitlebar.topRowLine(in: f.window))
            try #require(WindowTitlebar.isInTopRow(f.strip))
            #expect(abs(try pillCenterFromTop(f) - line.centerY) <= 0.5, "moved up onto the top row, the pill takes the line")
            #expect(try pillTop(f) != centered(f))
            let button = f.toolbar.convert(f.toolbar.moreButton.frame, to: nil)
            if TitlebarBandButton.side <= 2 * line.centerY {
                #expect(abs(f.container.bounds.maxY - button.midY - line.centerY) <= 0.5, "the toolbar's buttons take the line too")
            }
            #expect(f.toolbar.moreButton.frame.minY != buttonBelow)
        }
    }
}
