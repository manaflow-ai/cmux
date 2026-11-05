import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-04: "i feel like the restarted after nightly update does too many layout shifts/flicker
/// renderings". After a relaunch the "cmux Updated!" card took no room until its page drew (about a
/// second in), then the list above it made room on a spring and the page's later heights moved it again:
/// the relaunch bench counted a dozen sidebar frames per window (SidebarScrollView, SidebarListView,
/// WorkspaceRowView, SidebarUpdatedCardHost). The card now has its room in its first frame (the height
/// its page last reported) and its page's first height lands without the spring.
@MainActor
@Suite(.serialized)
struct UpdatedCardFirstFrameTests {
    final class FakeIsland: SidebarSurfaceIsland {
        let view = NSView()
        var contentHeight: CGFloat = 0
        var contentWidth: CGFloat = 0
        var onHeightChange: (() -> Void)?
        var onAction: (() -> Void)?
        var onDismiss: (() -> Void)?
        func close() {}
        func report(_ height: CGFloat) {
            contentHeight = height
            onHeightChange?()
        }
    }

    final class FakeSurfaces: SidebarUpdateSurfaces {
        var islands: [FakeIsland] = []
        func island(_ kind: SidebarUpdateSurfaceKind) -> any SidebarSurfaceIsland {
            let island = FakeIsland()
            islands.append(island)
            return island
        }
    }

    static let card = SidebarUpdatedCard(title: "Updated", whatsNewTitle: "See What's New", dismissLabel: "Close")
    static let key = "cmux.sidebar.updatedCard.height"
    static let widthsKey = "cmux.sidebar.updatedCard.heights"

    static func forget() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: widthsKey)
    }

    /// One launch's sidebar with the Updated card, laid out once before its page has drawn.
    static func launch(_ surfaces: FakeSurfaces, width: CGFloat = 260) -> SidebarView {
        let model = SidebarModel(sections: [])
        model.updatedCard = card
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        sidebar.updateSurfaces = surfaces
        sidebar.updatedCardView.configure(card)
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    @Test func aRelaunchedCardHasItsRoomBeforeItsPageDraws() throws {
        Self.forget()
        defer { Self.forget() }
        // The launch before the update: the page drew the card 77 pt tall.
        let before = FakeSurfaces()
        let first = Self.launch(before)
        try #require(before.islands.first).report(77)
        first.layoutSubtreeIfNeeded()
        #expect(first.updatedCardView.height == 77)
        let drawn = first.updatedCardView.frame
        #expect(drawn.height >= 77, "the card is laid out at its page's height (whole points)")

        // The relaunch: the new page has not drawn yet, and the card already stands where it stays.
        let after = FakeSurfaces()
        let relaunched = Self.launch(after)
        #expect(relaunched.updatedCardView.height == 77, "the card took no room until its page drew")
        #expect(!relaunched.updatedCardView.isHidden)
        #expect(relaunched.updatedCardView.frame == drawn, "the card's first frame is not its final one")
        let listBottom = relaunched.scrollView.frame.minY

        // The page draws at the same height: nothing moves.
        try #require(after.islands.first).report(77)
        relaunched.layoutSubtreeIfNeeded()
        #expect(relaunched.scrollView.frame.minY == listBottom, "the list moved when the page drew")
    }

    /// Review of #35624 (F2): a page with nothing to show reports 0, and the card hides, even with a
    /// remembered height (no blank glass card).
    @Test func aPageThatReportsNothingHidesTheRememberedCard() throws {
        UserDefaults.standard.set(77.0, forKey: Self.key)
        UserDefaults.standard.removeObject(forKey: Self.widthsKey)
        defer { Self.forget() }
        let surfaces = FakeSurfaces()
        let sidebar = Self.launch(surfaces)
        #expect(sidebar.updatedCardView.height == 77)
        try #require(surfaces.islands.first).report(0)
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.updatedCardView.height == 0, "a page that drew nothing kept a blank card")
        #expect(sidebar.updatedCardView.isHidden || sidebar.updatedCardView.frame.height == 0)
    }

    @Test func thePagesFirstHeightLandsWithoutTheSpring() throws {
        Self.forget()
        defer { Self.forget() }
        let surfaces = FakeSurfaces()
        let sidebar = Self.launch(surfaces)
        let window = NSWindow(contentRect: sidebar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = sidebar
        sidebar.layoutSubtreeIfNeeded()
        let island = try #require(surfaces.islands.first)

        island.report(64)
        sidebar.layoutSubtreeIfNeeded()
        #expect(!sidebar.cardSlotMotion.isMoving, "the list made room for the relaunched card on a spring")
        #expect(sidebar.updatedCardView.height == 64)
        let landed = sidebar.updatedCardView.frame
        #expect(landed.height >= 64)
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.updatedCardView.frame == landed, "the card moved after the frame its page's height landed in")
    }

    /// The relaunch bench at 7ed8d1ffedd: windows with sidebars of different widths wrap the card's words
    /// on different lines (a 196 pt card drew 77 pt, a 300 pt one 64 pt), and the one remembered height
    /// was whichever window reported last, so the other window's card moved 64 <-> 77 pt after its first
    /// frame. Each card width keeps its own height.
    @Test func eachSidebarWidthRemembersItsOwnCardHeight() throws {
        Self.forget()
        defer { Self.forget() }
        // The launch before the update: a narrow sidebar's card wraps to 77 pt, then a wide one's draws 64 pt.
        let narrowBefore = FakeSurfaces(), wideBefore = FakeSurfaces()
        let narrow = Self.launch(narrowBefore, width: 208)
        try #require(narrowBefore.islands.first).report(77)
        narrow.layoutSubtreeIfNeeded()
        let wide = Self.launch(wideBefore, width: 312)
        try #require(wideBefore.islands.first).report(64)
        wide.layoutSubtreeIfNeeded()

        // The relaunch: each window's card has its own height in its first frame.
        let narrowAgain = Self.launch(FakeSurfaces(), width: 208)
        let wideAgain = Self.launch(FakeSurfaces(), width: 312)
        #expect(narrowAgain.updatedCardView.height == 77, "the narrow card took the wide card's height")
        #expect(narrowAgain.updatedCardView.frame == narrow.updatedCardView.frame)
        #expect(wideAgain.updatedCardView.height == 64)
        #expect(wideAgain.updatedCardView.frame == wide.updatedCardView.frame)
    }
}
