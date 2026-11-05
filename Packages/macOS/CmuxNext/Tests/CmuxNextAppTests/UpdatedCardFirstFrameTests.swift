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

    /// The relaunch bench at 3f6fa2890d2, and any real update whose index on disk does not list the new
    /// build yet (fetched by the old app, offline, a slow network): the page waits 1.5 s for the span's
    /// notes, reports the host's items (64 pt), then the notes (77 pt). The card stood at its remembered
    /// 77 pt in its first frame, so it went 77 -> 64 -> 77 and the list moved twice. The card now keeps
    /// its first frame's height until its words are final, and stays there.
    @Test func aLateNotesLoadNeverResizesTheCardAfterItsFirstFrame() throws {
        Self.forget()
        defer { Self.forget() }
        let before = FakeSurfaces()
        let first = Self.launch(before)
        try #require(before.islands.first).report(77)
        first.layoutSubtreeIfNeeded()

        let after = FakeSurfaces()
        let relaunched = Self.launch(after)
        let window = NSWindow(contentRect: relaunched.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = relaunched
        relaunched.layoutSubtreeIfNeeded()
        let firstFrame = relaunched.updatedCardView.frame, listBottom = relaunched.scrollView.frame.minY
        #expect(relaunched.updatedCardView.height == 77)
        let island = try #require(after.islands.first)

        // The 1.5 s settle: the host's items, one line shorter.
        island.report(64)
        relaunched.layoutSubtreeIfNeeded()
        #expect(relaunched.updatedCardView.height == 77, "the card shrank to the host's items after its first frame")
        #expect(relaunched.updatedCardView.frame == firstFrame)
        #expect(relaunched.scrollView.frame.minY == listBottom, "the list moved when the host's items drew")

        // The span's notes, late: the words the card had room for.
        island.report(77)
        relaunched.layoutSubtreeIfNeeded()
        #expect(!relaunched.cardSlotMotion.isMoving, "the list moved on a spring when the notes arrived")
        #expect(relaunched.updatedCardView.frame == firstFrame, "the card moved when its notes arrived")
        #expect(relaunched.scrollView.frame.minY == listBottom, "the list moved when the notes arrived")
    }

    /// A card whose final words are shorter than last launch's keeps its first frame's height for this
    /// launch (no move after the first frame) and remembers its real height for the next one.
    @Test func shorterFinalWordsKeepTheFirstFrameAndAreRememberedForTheNextLaunch() throws {
        Self.forget()
        defer { Self.forget() }
        let before = FakeSurfaces()
        let first = Self.launch(before)
        try #require(before.islands.first).report(77)
        first.layoutSubtreeIfNeeded()

        let after = FakeSurfaces()
        let relaunched = Self.launch(after)
        let firstFrame = relaunched.updatedCardView.frame
        try #require(after.islands.first).report(64)
        relaunched.layoutSubtreeIfNeeded()
        #expect(relaunched.updatedCardView.frame == firstFrame, "the card shrank after its first frame")

        let next = Self.launch(FakeSurfaces())
        #expect(next.updatedCardView.height == 64, "the next launch did not take this launch's real height")
    }

    /// Review of #36045 (F1): the index on disk lists the update, but its notes are not on disk (never
    /// fetched, or their signature no longer verifies), so the page asks the network for them, settles at
    /// 1.5 s on the host's items and reports again when (or if) the notes come. Both sequences keep the
    /// card at its first frame's height: the notes late, and the notes never.
    @Test func aCachedIndexWithNotesMissingOnDiskKeepsTheCardsHeight() throws {
        for notesArrive in [true, false] {
            Self.forget()
            defer { Self.forget() }
            let before = FakeSurfaces()
            let first = Self.launch(before)
            try #require(before.islands.first).report(77)
            first.layoutSubtreeIfNeeded()

            let after = FakeSurfaces()
            let relaunched = Self.launch(after)
            let firstFrame = relaunched.updatedCardView.frame, listBottom = relaunched.scrollView.frame.minY
            let island = try #require(after.islands.first)
            island.report(64)
            relaunched.layoutSubtreeIfNeeded()
            if notesArrive {
                island.report(77)
                relaunched.layoutSubtreeIfNeeded()
            }
            #expect(relaunched.updatedCardView.frame == firstFrame, "the card moved (notes arrive: \(notesArrive))")
            #expect(relaunched.scrollView.frame.minY == listBottom, "the list moved (notes arrive: \(notesArrive))")
        }
    }
}

