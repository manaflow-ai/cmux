import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Aziz 2026-11-10 (screenshot of the What's New popover beside the sidebar's Updated card): the
/// popover must close the moment the pointer leaves both the card and the popover; it lingered a few
/// seconds. It waited 250 ms, then kept waiting up to 1.2 s more while the pointer was anywhere in a
/// band from the card's middle to the popover and as tall as both, which covers the sidebar's rows.
@MainActor @Suite(.serialized, .closesItsWindows) struct UpdatedNotesCloseAtOnceTests {
    // MARK: The decision

    private static let card = CGRect(x: 100, y: 100, width: 200, height: 48)
    /// The popover beside the card, one pixel from its edge, taller than it and reaching below.
    private static let notes = CGRect(x: 300.5, y: -60, width: 320, height: 208)

    @Test func onTheCardOrThePopoverItStays() {
        #expect(SidebarUpdatedNotesPopover.closeStep(pointer: CGPoint(x: 290, y: 140), card: Self.card, notes: Self.notes) == .stay)
        #expect(SidebarUpdatedNotesPopover.closeStep(pointer: CGPoint(x: 400, y: 0), card: Self.card, notes: Self.notes) == .stay)
    }

    @Test func inTheSeamBetweenThemItWaits() {
        #expect(SidebarUpdatedNotesPopover.closeStep(pointer: CGPoint(x: 300.2, y: 120), card: Self.card, notes: Self.notes) == .wait)
    }

    /// The sidebar's rows beside and above the card, and the content past the popover: it closes now.
    @Test func offBothItClosesAtOnce() {
        for point in [CGPoint(x: 250, y: 200), CGPoint(x: 150, y: 160), CGPoint(x: 299, y: 50), CGPoint(x: 700, y: 120),
                      CGPoint(x: 400, y: 250), CGPoint(x: 50, y: 120)] {
            #expect(SidebarUpdatedNotesPopover.closeStep(pointer: point, card: Self.card, notes: Self.notes) == .close,
                    "\(point) kept the popover open")
        }
    }

    /// The usual rest at the sidebar's foot: the popover clamped into the window, mostly above the card.
    private static let raised = CGRect(x: 300.5, y: 120, width: 320, height: 400)

    /// A slanted move from the card's top edge toward the middle of a raised popover is on its way.
    @Test func aimingAtARaisedPopoverWaits() {
        let left = CGPoint(x: 250, y: 148)
        #expect(SidebarUpdatedNotesPopover.closeStep(pointer: CGPoint(x: 280, y: 250), card: Self.card, notes: Self.raised, from: left) == .wait)
    }

    /// Leaving the card for the rows above it, or back left: not toward the popover, so it closes now.
    @Test func leavingTheCardAwayFromThePopoverClosesEvenWithAnAim() {
        let left = CGPoint(x: 250, y: 148)
        for point in [CGPoint(x: 150, y: 300), CGPoint(x: 240, y: 200), CGPoint(x: 90, y: 120)] {
            #expect(SidebarUpdatedNotesPopover.closeStep(pointer: point, card: Self.card, notes: Self.raised, from: left) == .close,
                    "\(point) kept the popover open")
        }
    }

    /// Leaving the popover toward the card aims at the card, not back at the popover.
    @Test func leavingThePopoverAimsAtTheCard() {
        let left = CGPoint(x: 300.5, y: 300)
        #expect(SidebarUpdatedNotesPopover.closeStep(pointer: CGPoint(x: 299, y: 200), card: Self.card, notes: Self.raised,
                                                     from: left, towardNotes: false) == .wait)
        #expect(SidebarUpdatedNotesPopover.closeStep(pointer: CGPoint(x: 299, y: 400), card: Self.card, notes: Self.raised,
                                                     from: left, towardNotes: false) == .close)
    }

    // MARK: The popover

    final class Page: SidebarSurfaceIsland {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        var contentHeight: CGFloat = 200
        var contentWidth: CGFloat = 0
        var onHeightChange: (() -> Void)?
        var onAction: (() -> Void)?
        var onDismiss: (() -> Void)?
        func close() {}
        var overlayHeight: CGFloat = 0
        var previewHeight: CGFloat = 0
    }

    final class Surfaces: SidebarUpdateSurfaces {
        func island(_ kind: SidebarUpdateSurfaceKind) -> any SidebarSurfaceIsland { Page() }
    }

    /// A shown popover beside a card in a window, with the pointer the test places.
    struct Harness {
        let popover: SidebarUpdatedNotesPopover
        let cards: HoverCardCoordinator
        let window: NSWindow
        let card: NSView
        let surfaces: Surfaces
        var cardFrame: CGRect { window.convertToScreen(card.convert(card.bounds, to: nil)) }

        func tearDown() {
            popover.tearDown()
            cards.cardWindow?.closeAfterTest()
            window.closeAfterTest()
        }
    }

    private func make(pointer: @escaping () -> CGPoint) throws -> Harness {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let card = NSView(frame: NSRect(x: 12, y: 60, width: 240, height: 48))
        window.contentView?.addSubview(card)
        window.orderFrontRegardless()
        let cards = HoverCardCoordinator()
        let surfaces = Surfaces()
        let popover = SidebarUpdatedNotesPopover()
        popover.surfaces = surfaces
        popover.hoverCards = { cards }
        popover.screenPointer = pointer
        popover.prepare(in: card, enabled: true)
        let h = Harness(popover: popover, cards: cards, window: window, card: card, surfaces: surfaces)
        popover.cardHovered(true)
        popover.show(force: true)
        return h
    }

    @Test func leavingTheCardForTheRowsClosesItAtOnce() async throws {
        var pointer = CGPoint.zero
        let h = try make { pointer }
        defer { h.tearDown() }
        pointer = CGPoint(x: h.cardFrame.midX, y: h.cardFrame.midY)
        try #require(h.popover.isShown, "the popover did not show")
        // Up into the sidebar's rows above the card: inside the old corridor, on neither.
        pointer = CGPoint(x: h.cardFrame.maxX - 20, y: h.cardFrame.maxY + 60)
        h.popover.cardHovered(false)
        // At once: the first frame learns the pointer's way (it left from where it is), the next closes.
        #expect(await eventually(.milliseconds(150)) { !h.popover.isShown }, "the popover lingered after the pointer left the card and the popover")
    }

    @Test func movingFromTheCardIntoThePopoverKeepsIt() throws {
        var pointer = CGPoint.zero
        let h = try make { pointer }
        defer { h.tearDown() }
        let notes = try #require(h.popover.frame, "the popover did not show")
        pointer = CGPoint(x: notes.midX, y: notes.midY)
        h.popover.cardHovered(false)
        #expect(h.popover.isShown, "the popover closed under the pointer")
    }

    @Test func leavingThePopoverForTheContentClosesItAtOnce() async throws {
        var pointer = CGPoint.zero
        let h = try make { pointer }
        defer { h.tearDown() }
        let notes = try #require(h.popover.frame, "the popover did not show")
        pointer = CGPoint(x: notes.midX, y: notes.midY)
        h.popover.cardHovered(false)
        h.popover.host.onPointerEnter?()
        pointer = CGPoint(x: notes.maxX + 80, y: notes.midY)
        h.popover.host.onPointerExit?()
        #expect(await eventually(.milliseconds(150)) { !h.popover.isShown }, "the popover lingered after the pointer left it for the content")
    }

    /// The popover's exit can come before the card's hover hears the pointer arrive: the card's frame decides.
    @Test func leavingThePopoverBackOntoTheCardKeepsIt() throws {
        var pointer = CGPoint.zero
        let h = try make { pointer }
        defer { h.tearDown() }
        let notes = try #require(h.popover.frame, "the popover did not show")
        pointer = CGPoint(x: notes.midX, y: notes.midY)
        h.popover.cardHovered(false)
        pointer = CGPoint(x: h.cardFrame.midX, y: h.cardFrame.midY)
        h.popover.host.onPointerExit?()
        #expect(h.popover.isShown, "the popover closed with the pointer back on its card")
    }

    /// Waits up to `limit` for `done` (the popover's close runs on its own frame timer).
    private func eventually(_ limit: Duration = .seconds(2), _ done: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10)) // test-only: waits for the popover's close timer, bounded
        }
        return done()
    }

    /// The card's hover went off while the pointer was still on the card (its hover can lag the
    /// geometry): the popover stays, then closes once the pointer leaves for the rows with no new hover event.
    @Test func aCardHoverThatLagsStillClosesOnceThePointerLeaves() async throws {
        var pointer = CGPoint.zero
        let h = try make { pointer }
        defer { h.tearDown() }
        try #require(h.popover.isShown, "the popover did not show")
        pointer = CGPoint(x: h.cardFrame.midX, y: h.cardFrame.midY)
        h.popover.cardHovered(false)
        #expect(h.popover.isShown, "the popover closed with the pointer on its card")
        pointer = CGPoint(x: h.cardFrame.midX - 40, y: h.cardFrame.maxY + 80)
        #expect(await eventually { !h.popover.isShown }, "the popover stayed open after the pointer left the card")
    }

    /// In the seam and never arriving: the wait ends and the popover closes.
    @Test func aPointerThatStopsInTheSeamClosesAfterTheLimit() async throws {
        var pointer = CGPoint.zero
        let h = try make { pointer }
        defer { h.tearDown() }
        let notes = try #require(h.popover.frame, "the popover did not show")
        let gapX = (h.cardFrame.maxX + notes.minX) / 2
        pointer = CGPoint(x: gapX, y: max(h.cardFrame.minY, notes.minY) + 2)
        h.popover.cardHovered(false)
        #expect(h.popover.isShown, "the popover closed while the pointer crossed the seam")
        #expect(await eventually { !h.popover.isShown }, "the popover never closed with the pointer resting in the seam")
    }
}
