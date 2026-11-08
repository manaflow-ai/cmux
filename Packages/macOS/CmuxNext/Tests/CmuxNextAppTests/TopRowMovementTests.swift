import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// A pane that only moves in its window (a column or row scroll, a split, the sidebar's slide, a pane
/// coming to rest) skips its content's layout: the App tells its strip (`updateWindowControlsAvoidance`),
/// which re-checks the top row's line as well as the traffic lights (review of #37619). A top-row strip
/// moved down leaves the line for its own centering, and a lower strip moved up onto the top row takes
/// the line, with no resize; the pane's toolbar follows its strip both ways.
@MainActor @Suite(.closesItsWindows, .serialized) struct TopRowMovementTests {
    func with(_ body: () throws -> Void) rethrows {
        let design = DesignSettings.shared
        let before = (design.tabBarPosition, design.titlebar, design.densityTokens)
        design.tabBarPosition = .top
        design.titlebar = .minimal
        // Comfortable: its strip's own centering and the lights' line differ by 2 pt, so a stale layout shows.
        design.densityTokens = DensityPreset.comfortable.tokens
        defer { (design.tabBarPosition, design.titlebar, design.densityTokens) = before }
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

    /// The pill's center below the window's top edge.
    func pillCenterFromTop(_ f: Fixture) throws -> CGFloat {
        let pill = f.strip.convert(try #require(f.strip.firstTabPillFrame), to: nil)
        return f.container.bounds.maxY - pill.midY
    }

    @Test func aTopRowStripMovedDownLeavesTheLine() throws {
        try with {
            let f = fixture(topRow: true)
            defer { f.window.closeAfterTest() }
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

    @Test func aLowerStripMovedUpTakesTheLine() throws {
        try with {
            let f = fixture(topRow: false)
            defer { f.window.closeAfterTest() }
            #expect(!WindowTitlebar.isInTopRow(f.strip))
            #expect(try pillTop(f) == centered(f))
            let buttonBelow = f.toolbar.moreButton.frame.minY

            move(f, by: f.container.bounds.maxY - f.strip.frame.maxY)
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
