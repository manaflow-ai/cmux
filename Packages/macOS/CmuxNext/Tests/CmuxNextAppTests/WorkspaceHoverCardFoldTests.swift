import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
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

        f.card.detailsToggle.performClick(nil)
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
        f.card.detailsToggle.performClick(nil)
        Self.settle(f.panel)
        let expanded = f.surface.size
        let expandedBody = f.card.frame.size

        f.card.detailsToggle.performClick(nil)
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

    @Test func underReduceMotionDetailsChangeTheCardAtOnce() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let f = try Self.fixture()
        defer { f.tearDown() }
        let collapsed = f.surface.size
        f.card.detailsToggle.performClick(nil)
        #expect(f.panel.activeMorph == nil)
        #expect(f.surface.height > collapsed.height + 20)
        f.card.detailsToggle.performClick(nil)
        #expect(f.panel.activeMorph == nil)
        #expect(abs(f.surface.height - collapsed.height) < 0.5)
        #expect(abs(f.card.frame.height - f.surface.height) < 0.5)
    }
}
