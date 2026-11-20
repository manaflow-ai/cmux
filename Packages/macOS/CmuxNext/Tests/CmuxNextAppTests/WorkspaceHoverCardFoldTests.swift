import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxNextWakeups
import Testing

/// Lawrence 2026-11-17 (msg 38370, a recording of a sidebar workspace card's Show details and Hide details): "fix
/// jank like shadows stuff". Frame by frame, the card resized under a mask over a card laid out at the larger size:
/// the moving edge had no rim and square-cut corners, the shadow ran on springs of its own and was redrawn when the
/// card settled, and Hide details dropped the rows at once while an empty card and its shadow folded after them.
/// Now the card's surface (its rim and shadow with it) is drawn at the size the resize is at, and Hide details keeps
/// the rows laid out under the folding edge until the fold ends.
@MainActor @Suite(.serialized, .closesItsWindows) struct WorkspaceHoverCardFoldTests {
    private struct Fixture {
        let parent: NSWindow
        let panel: HoverCardPanel
        let card: WorkspaceHoverCardView
        var host: PopupHostView { panel.contentView as! PopupHostView } // swiftlint:disable:this force_cast

        /// The card's surface in the window, and the shape its shadow is cast from.
        var surface: CGRect { host.card.frame }
        var shadowShape: CGRect { host.shadowLayer.shadowPath?.boundingBoxOfPath ?? .null }
        /// The size the resize in flight shows now (the card's rest size when none runs).
        var shown: CGSize { panel.presentedSize.size }

        func tearDown() {
            panel.closeAfterTest()
            parent.close()
        }
    }

    private static func fixture() throws -> Fixture {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFrontRegardless()
        let card = WorkspaceHoverCardView()
        card.configure(WorkspaceHoverCardFixture.content, now: WorkspaceHoverCardFixture.now)
        card.configureTabs(title: WorkspaceHoverCardFixture.title, tabs: Array(WorkspaceHoverCardFixture.tabs.prefix(2)),
                           now: WorkspaceHoverCardFixture.now)
        let panel = HoverCardPanel()
        card.onDetailsChanged = { [weak panel] in panel?.refit(animated: true) }
        let row = CGRect(x: parent.frame.minX, y: parent.frame.maxY - 80, width: parent.frame.width, height: 30)
        panel.present(body: card, anchor: row, placement: .besideRow, parent: parent, themeAnchor: nil, sliding: false, applyTheme: {})
        try #require(panel.isShowingCard, "the card did not show")
        try #require(!card.detailsToggle.isHidden, "the fixture's card has no Show details")
        return Fixture(parent: parent, panel: panel, card: card)
    }

    /// Presses Show details or Hide details and delivers the card window's next frame, whose start runs the press.
    private static func press(_ f: Fixture) {
        f.card.detailsToggle.performClick(nil)
        FrameScheduler.forWindow(f.panel).frameDidFire()
    }

    /// Ends the resize in flight where it was going (the window's clock would after its last frame).
    private static func settle(_ panel: HoverCardPanel) {
        guard let generation = panel.activeMorph?.generation else { return }
        panel.finishMorph(generation)
    }

    @Test func showDetailsGrowsTheCardsRealSurfaceAndItsShadowTogether() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = try Self.fixture()
        defer { f.tearDown() }
        let collapsed = f.surface.size

        Self.press(f)
        try #require(f.panel.activeMorph != nil, "Show details did not resize the card on its spring")
        // The first frame shows the card at the size it had: its surface (so its rim and corners) is that size,
        // not a larger card cut by a mask whose moving edge has no rim.
        #expect(f.panel.glass.layer?.mask == nil, "the card resizes under a mask that cuts its rim and corners off the moving edge")
        #expect(abs(f.surface.height - f.shown.height) < 0.5 && abs(f.surface.width - f.shown.width) < 0.5,
                "the card's surface is \(f.surface.size) while the resize shows \(f.shown)")
        #expect(abs(f.surface.height - collapsed.height) < 0.5, "the card jumped to \(f.surface.height) pt on Show details, from \(collapsed.height)")
        #expect(f.shadowShape == f.surface, "the shadow is cast from \(f.shadowShape), not the card's surface \(f.surface)")

        Self.settle(f.panel)
        #expect(f.surface.height > collapsed.height + 20, "Show details did not grow the card (\(f.surface.height) pt)")
        #expect(f.shadowShape == f.surface, "at rest the shadow is cast from \(f.shadowShape), not the card \(f.surface)")
    }

    @Test func hideDetailsFoldsTheCardOverItsRowsNotAnEmptyCard() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = try Self.fixture()
        defer { f.tearDown() }
        Self.press(f)
        Self.settle(f.panel)
        let expanded = f.surface.size
        let expandedBody = f.card.frame.size

        Self.press(f)
        try #require(f.panel.activeMorph != nil, "Hide details did not fold the card on its spring")
        // The card starts folding from its expanded size with the rows it showed still laid out under it.
        #expect(abs(f.surface.height - expanded.height) < 0.5, "the card's surface is \(f.surface.height) pt as the fold starts, not \(expanded.height)")
        #expect(abs(f.card.frame.height - expandedBody.height) < 0.5,
                "the rows went at once (\(f.card.frame.height) pt of content in a \(f.surface.height) pt card): an empty card folds after them")
        #expect(f.shadowShape == f.surface, "the shadow is cast from \(f.shadowShape), not the folding card \(f.surface)")
        #expect(f.card.detailsToggle.title == Strings.showDetails, "the toggle does not say Show details at once")

        Self.settle(f.panel)
        #expect(f.surface.height < expanded.height - 20, "Hide details did not fold the card (\(f.surface.height) pt)")
        #expect(abs(f.card.frame.height - f.surface.height) < 0.5, "after the fold the content is \(f.card.frame.height) pt in a \(f.surface.height) pt card")
        #expect(f.shadowShape == f.surface)
    }

    /// The sizes the card's surface takes and the window resizes it makes while `body` runs.
    private static func sizes(of f: Fixture, during body: () -> Void) -> (surface: [CGSize], windowResizes: Int) {
        var surface: [CGSize] = []
        var resizes = 0
        f.host.card.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        let a = center.addObserver(forName: NSView.frameDidChangeNotification, object: f.host.card, queue: nil) { _ in
            MainActor.assumeIsolated { if surface.last != f.host.card.frame.size { surface.append(f.host.card.frame.size) } }
        }
        let b = center.addObserver(forName: NSWindow.didResizeNotification, object: f.panel, queue: nil) { _ in resizes += 1 }
        body()
        center.removeObserver(a)
        center.removeObserver(b)
        return (surface, resizes)
    }

    /// Lawrence 2026-11-18 (msg 38370 follow-up): the press of Show details or Hide details was one late frame
    /// on 36 to 37 of 40 presses (cmux-lawrence-2, 120 Hz): the press laid the card and its glass out at sizes it
    /// never showed. Hide details set the window to the small rest frame, laid it out, then set it back to the
    /// fold's larger frame; Show details laid the card out at the full larger size, then again at the size it grows
    /// from. The press lays the card out once, at the size its first frame shows.
    @Test func pressingDetailsLaysTheCardOutOnlyAtTheSizeItShows() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = try Self.fixture()
        defer { f.tearDown() }

        let show = Self.sizes(of: f) { Self.press(f) }
        try #require(f.panel.activeMorph != nil)
        #expect(show.surface.allSatisfy { abs($0.height - f.shown.height) < 0.5 && abs($0.width - f.shown.width) < 0.5 },
                "Show details laid the card out at \(show.surface) before showing it at \(f.shown)")
        #expect(show.windowResizes <= 1, "Show details resized the card's window \(show.windowResizes) times")
        Self.settle(f.panel)

        let hide = Self.sizes(of: f) { Self.press(f) }
        try #require(f.panel.activeMorph != nil)
        #expect(hide.surface.allSatisfy { abs($0.height - f.shown.height) < 0.5 && abs($0.width - f.shown.width) < 0.5 },
                "Hide details laid the card out at \(hide.surface) before showing it at \(f.shown)")
        #expect(hide.windowResizes == 0, "Hide details resized the card's window \(hide.windowResizes) times: the fold holds the frame it had")
    }

    /// Lawrence 2026-11-18 (msg 38370 follow-up): the press of Show details or Hide details skipped a display frame
    /// on 36 to 37 of 40 presses (cmux-lawrence-2, 120 Hz): the card's layout, measure and first resize frame ran in
    /// the press, at any point of a frame, and crossed its end. The press now runs at the start of the card window's
    /// next frame, where that work fits; the press itself changes nothing.
    @Test func aDetailsPressRunsAtTheStartOfTheNextFrameNotInThePress() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = try Self.fixture()
        defer { f.tearDown() }
        let collapsed = f.surface.size

        f.card.detailsToggle.performClick(nil)
        #expect(f.panel.activeMorph == nil, "Show details resized the card inside the press")
        #expect(!f.card.isDetailsExpanded && f.surface.size == collapsed, "Show details changed the card inside the press")
        FrameScheduler.forWindow(f.panel).frameDidFire()
        #expect(f.card.isDetailsExpanded, "the next frame did not run the press")
        #expect(f.panel.activeMorph != nil, "the next frame did not start the card's resize")
        Self.settle(f.panel)

        // Two presses before one frame: the card stays as it is.
        let expanded = f.surface.size
        f.card.detailsToggle.performClick(nil)
        f.card.detailsToggle.performClick(nil)
        FrameScheduler.forWindow(f.panel).frameDidFire()
        #expect(f.card.isDetailsExpanded && f.panel.activeMorph == nil && f.surface.size == expanded)
    }

    /// Lawrence 2026-11-18 (msg 38370 follow-up): a details press was 4 to 5 ms of main-thread work on cmux-lawrence-2,
    /// 58% of it the measure's temporary layout engine (`fittingSize`); Hide details hid its rows and showed them again
    /// for the fold, and the chevron's image was made again on each press. A press now resizes the card from the sizes
    /// it measured while it rested, keeps Hide details' rows laid out from the press, and reuses the chevron's images.
    @Test func aDetailsPressMeasuresNothingAndRemakesNothing() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = try Self.fixture()
        defer { f.tearDown() }
        Self.settle(f.panel)
        f.card.prepareSizes()
        let collapsedChevron = f.card.detailsToggle.shownChevron
        var measures = (f.panel.contentMeasures, f.card.selfMeasures)

        Self.press(f)
        try #require(f.panel.activeMorph != nil, "Show details did not resize the card")
        #expect(f.panel.contentMeasures == measures.0, "Show details measured the card's content in the panel")
        #expect(f.card.selfMeasures == measures.1, "Show details measured the card in the press")
        Self.settle(f.panel)
        f.card.prepareSizes()
        measures = (f.panel.contentMeasures, f.card.selfMeasures)
        let hidings = f.card.detailRowsHidings

        Self.press(f)
        try #require(f.panel.activeMorph != nil, "Hide details did not fold the card")
        #expect(f.panel.contentMeasures == measures.0, "Hide details measured the card's content in the panel")
        #expect(f.card.selfMeasures == measures.1, "Hide details measured the card in the press")
        #expect(f.card.detailRowsHidings == hidings, "Hide details hid its rows in the press and showed them again for the fold")
        Self.settle(f.panel)
        #expect(f.card.detailRowsHidings == hidings + 1, "the fold's end did not take the rows")
        #expect(f.card.detailsToggle.shownChevron === collapsedChevron, "the chevron's image was made again")
    }

    /// The size the card reports is the size a measure gives, in both details states and after its content changes,
    /// and the card rests at it.
    @Test func theCardsReportedSizeIsItsMeasuredSize() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = try Self.fixture()
        defer { f.tearDown() }
        Self.settle(f.panel)
        f.card.prepareSizes()
        #expect(f.card.reportedFittingSize == f.card.fittingSize, "collapsed: the card reports \(String(describing: f.card.reportedFittingSize)), a measure gives \(f.card.fittingSize)")
        Self.press(f)
        Self.settle(f.panel)
        f.card.prepareSizes()
        #expect(f.card.reportedFittingSize == f.card.fittingSize, "expanded: the card reports \(String(describing: f.card.reportedFittingSize)), a measure gives \(f.card.fittingSize)")
        #expect(f.surface.size == f.card.fittingSize, "the card rests at \(f.surface.size), its measure is \(f.card.fittingSize)")
        // What the card shows changes: the size it reports follows.
        var content = WorkspaceHoverCardFixture.content
        content.facts += [.init(icon: .folder, text: "a second fact, long enough to widen the card's text a little", kind: "folder")]
        f.card.configure(content, now: WorkspaceHoverCardFixture.now)
        #expect(f.card.reportedFittingSize == f.card.fittingSize, "after a content change the card reports \(String(describing: f.card.reportedFittingSize)), a measure gives \(f.card.fittingSize)")
    }

    @Test func underReduceMotionDetailsChangeTheCardAtOnce() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let f = try Self.fixture()
        defer { f.tearDown() }
        let collapsed = f.surface.size
        Self.press(f)
        #expect(f.panel.activeMorph == nil)
        #expect(f.surface.height > collapsed.height + 20)
        Self.press(f)
        #expect(f.panel.activeMorph == nil)
        #expect(abs(f.surface.height - collapsed.height) < 0.5)
        #expect(abs(f.card.frame.height - f.surface.height) < 0.5)
    }
}
