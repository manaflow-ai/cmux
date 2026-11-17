@testable import CmuxNextDesign
import AppKit
import CmuxNextDesignTokens
import CmuxNextTestSupport
import CmuxNextWakeupsTestSupport
import Testing

/// User 2026-11-16: "for horizontal tabs i should not be able to hover mouse over horiztonal tab preview
/// popover thing. for vertical tab preview, yes tho." Both cards hide when the pointer leaves their
/// target (`HoverCardLeave.hides`), and both touch it, so the pointer reaches the card in one move.
/// The coordinator counted the pointer on the shown card as on the card for every target: the hit was
/// nil and bridging, the machine went to `.leaving`, and each deadline found the pointer on the card and
/// kept it. A target that is not `enterable` (a horizontal tab's card) now treats the card as anywhere
/// else off its target: the card fades out on that move. An enterable one (the sidebar's) keeps it.
@MainActor @Suite(.closesItsWindows, .serialized)
struct HoverCardEnterableTests {
    @MainActor
    private final class Source: HoverCardSource {
        let window: NSWindow
        let anchor: CGRect
        let target: HoverTarget
        init(window: NSWindow, anchor: CGRect, target: HoverTarget) {
            self.window = window
            self.anchor = anchor
            self.target = target
        }
        var hoverCardWindow: NSWindow? { window }
        func hoverCardHit(at point: CGPoint) -> HoverCardHit? {
            anchor.contains(point) ? HoverCardHit(target: target, anchor: anchor) : nil
        }
        func hoverCardAnchor(for id: HoverTargetID) -> CGRect? { id == target.id ? anchor : nil }
        func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? {
            // A label sizes itself: the card is as wide and tall as its text, with the panel's padding.
            let body = NSTextField(labelWithString: "A card body with two lines\nof text that the pointer can reach")
            body.maximumNumberOfLines = 2
            return HoverCardBody(view: body, placement: .below, themeAnchor: nil) {}
        }
        func hoverCardActivated(_: HoverTargetID) {}
        func hoverCardDeactivated(_: HoverTargetID) {}
    }

    private struct Harness {
        let coordinator: HoverCardCoordinator
        let window: NSWindow
        let source: Source
        let clock: ManualClock
        var shown: Bool { coordinator.isShowing(source.target.id) }

        func tearDown() {
            coordinator.dismiss(.action)
            ([coordinator.panel] + coordinator.retiring).forEach { $0?.closeAfterTest() }
            window.close()
        }
    }

    /// A target whose card shows on the first move onto it (no delay) and hides on leave.
    private static func harness(enterable: Bool) -> Harness {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        let target = HoverTarget(id: HoverTargetID(enterable ? "row:a" : "tab:a"), window: window.windowNumber, delay: .zero,
                                 leave: .hides(reshow: HoverCardTiming.reshowWindow), enterable: enterable)
        let source = Source(window: window, anchor: CGRect(x: 200, y: 640, width: 180, height: 30), target: target)
        let clock = ManualClock()
        let coordinator = HoverCardCoordinator(clock: clock)
        coordinator.appIsActive = { true }
        coordinator.hoverCardsEnabled = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.windowNumberAt = { [weak window] _ in window?.windowNumber }
        // A still real mouse: the coordinator takes each pointer event's own point.
        coordinator.pointerLocation = { .zero }
        coordinator.register(source)
        return Harness(coordinator: coordinator, window: window, source: source, clock: clock)
    }

    private static func settle() async throws {
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(30))
    }

    /// Shows the card, then moves the pointer off the target straight onto the card.
    private static func moveOntoTheCard(_ h: Harness) throws -> CGRect {
        h.coordinator.pointerMoved(to: CGPoint(x: h.source.anchor.midX, y: h.source.anchor.midY))
        try #require(h.shown, "a move onto the target showed no card")
        let card = try #require(h.coordinator.panel?.cardFrame)
        try #require(card.width > 40 && card.height > 20, "the card \(card) has no room for the pointer")
        try #require(card.maxY <= h.source.anchor.minY + 0.5, "the card \(card) is not below its target \(h.source.anchor)")
        let onto = CGPoint(x: card.midX, y: card.maxY - 6)
        try #require(card.contains(onto) && !h.source.anchor.contains(onto))
        h.coordinator.pointerMoved(to: onto)
        return card
    }

    @Test func aCardThatIsNotEnterableHidesAsThePointerMovesOntoIt() async throws {
        let h = Self.harness(enterable: false)
        defer { h.tearDown() }
        let card = try Self.moveOntoTheCard(h)
        #expect(!h.shown, "the pointer on the card kept it: \(h.coordinator.machine.phase)")
        #expect(h.coordinator.panel?.isShowingCard != true, "the card did not start to fade on the move onto it")
        // Resting there past the reshow window: nothing comes back.
        h.coordinator.cardPointerMoved(CGPoint(x: card.midX, y: card.midY))
        try await h.clock.waitForSleeper()
        h.clock.advance(by: HoverCardTiming.reshowWindow + .milliseconds(100))
        try await Self.settle()
        #expect(h.coordinator.machine.shownTarget == nil, "resting where the card was showed it again")
        #expect(!h.coordinator.pointerIsOnShownCard, "a hidden preview still counts the pointer as on it")
    }

    @Test func anEnterableCardStaysWithThePointerOnIt() async throws {
        let h = Self.harness(enterable: true)
        defer { h.tearDown() }
        let card = try Self.moveOntoTheCard(h)
        #expect(h.shown, "moving from the target onto its card hid it")
        // Resting on the card past the reshow window keeps it.
        h.coordinator.cardPointerMoved(CGPoint(x: card.midX, y: card.midY))
        try await h.clock.waitForSleeper()
        h.clock.advance(by: HoverCardTiming.reshowWindow + .milliseconds(100))
        try await Self.settle()
        #expect(h.shown, "the card hid with the pointer resting on it: \(h.coordinator.machine.phase)")
        #expect(h.coordinator.pointerIsOnShownCard, "the pointer on the card does not count as on it")
        // Off the card and the target: it hides on that move.
        h.coordinator.pointerMoved(to: CGPoint(x: card.maxX + 200, y: card.midY))
        #expect(!h.shown, "the card stayed after the pointer left it and its target")
    }
}
