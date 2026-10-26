import AppKit
@testable import CmuxNextDesign
import CmuxNextInput
import CmuxNextWakeupsTestSupport
import Testing

/// The hover card coordinator listens on the app's one input tap, not AppKit event monitors
/// (p04-input-013): only while a card is pending or shown it holds a dismissal intercept of order
/// `.popup`, and a key press, click or wheel scroll ends the card and goes on.
@MainActor @Suite(.serialized) struct HoverCardCoordinatorTests {
    private final class Source: HoverCardSource {
        let window: NSWindow
        init(window: NSWindow) { self.window = window }
        var hoverCardWindow: NSWindow? { window }
        func hoverCardHit(at screenPoint: CGPoint) -> HoverCardHit? {
            guard window.frame.contains(screenPoint) else { return nil }
            let target = HoverTarget(id: HoverTargetID("tab"), window: window.windowNumber, delay: .milliseconds(500))
            return HoverCardHit(target: target, anchor: window.frame)
        }
        func hoverCardAnchor(for id: HoverTargetID) -> CGRect? { window.frame }
        func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? { nil }
        func hoverCardActivated(_ id: HoverTargetID) {}
        func hoverCardDeactivated(_ id: HoverTargetID) {}
    }

    /// A coordinator with a pending card for the window's one target, listening on `events`' tap.
    private static func pendingCard(_ events: InputTapTestEvents, window: NSWindow, source: Source) throws -> HoverCardCoordinator {
        let coordinator = HoverCardCoordinator(clock: ManualClock())
        coordinator.inputTap = { events.tap }
        coordinator.register(source)
        let frame = window.frame
        coordinator.pointerLocation = { CGPoint(x: frame.midX, y: frame.midY) }
        coordinator.appIsActive = { true }
        coordinator.hoverCardsEnabled = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.windowNumberAt = { _ in window.windowNumber }
        coordinator.ownWindows = { [(number: window.windowNumber, frame: frame)] }
        #expect(events.subscriptions == 0, "the coordinator listens before any card")
        coordinator.pointerMoved()
        try #require(coordinator.machine.activeTarget?.id == HoverTargetID("tab"), "no pending card: \(coordinator.machine.phase)")
        return coordinator
    }

    @Test func aPendingCardHoldsOneDismissalInterceptAndAKeyPressEndsIt() throws {
        let events = InputTapTestEvents()
        let window = InputTapTestEvents.window()
        defer { window.orderOut(nil) }
        let source = Source(window: window)
        let coordinator = try Self.pendingCard(events, window: window, source: source)
        defer { coordinator.unregister(source) }
        for eventClass in [InputEventClass.key, .button, .scroll] {
            #expect(events.tap.subscriberCount(eventClass, stage: .intercept) == 1, "no \(eventClass) dismissal intercept")
        }
        #expect(coordinator.report["dismissal_subscription"] == "true")

        #expect(!events.dispatch(try InputTapTestEvents.key(.keyUp, keyCode: 0, in: window)))
        #expect(coordinator.machine.activeTarget != nil, "a key up ended the card")
        #expect(!events.dispatch(try InputTapTestEvents.key(.keyDown, keyCode: 0, in: window)), "the key press was swallowed")
        #expect(coordinator.machine.activeTarget == nil, "a key press kept the card")
        #expect(events.subscriptions == 0, "the dismissal intercept outlived the card")
    }

    @Test func aClickOrAScrollOffTheCardEndsItAndGoesOn() throws {
        for event in [try InputTapTestEvents.mouse(.leftMouseDown), try InputTapTestEvents.scroll()] {
            let events = InputTapTestEvents()
            let window = InputTapTestEvents.window()
            defer { window.orderOut(nil) }
            let source = Source(window: window)
            let coordinator = try Self.pendingCard(events, window: window, source: source)
            defer { coordinator.unregister(source) }
            #expect(!events.dispatch(event), "\(event.type) was swallowed")
            #expect(coordinator.machine.activeTarget == nil, "\(event.type) kept the card")
            #expect(events.subscriptions == 0)
        }
    }
}
