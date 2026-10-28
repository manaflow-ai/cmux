import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The hover card coordinator hears the app going inactive and a Space change through the
/// app's one AppEvents per center (recipe R-notif), made with its first source; a coordinator with no fan-outs
/// (a strip's default) subscribes to nothing.
@MainActor @Suite(.serialized) struct HoverCardAppNoticesTests {
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

    @Test func theFirstSourceSubscribesOnceAndASpaceChangeEndsAPendingCard() throws {
        let app = NotificationCenter(), workspace = NotificationCenter()
        let appEvents = AppEvents(center: app), workspaceEvents = AppEvents(center: workspace)
        let coordinator = HoverCardCoordinator(clock: ManualClock(), appEvents: appEvents, workspaceEvents: workspaceEvents)
        #expect(!appEvents.isObserving(NSApplication.didResignActiveNotification), "subscribed before any source")
        #expect(!workspaceEvents.isObserving(NSWorkspace.activeSpaceDidChangeNotification), "subscribed before any source")

        let window = InputTapTestEvents.window()
        defer { window.orderOut(nil) }
        let source = Source(window: window), other = Source(window: window)
        coordinator.register(source)
        coordinator.register(other)
        defer {
            coordinator.unregister(source)
            coordinator.unregister(other)
        }
        #expect(appEvents.subscriberCount(NSApplication.didResignActiveNotification) == 1)
        #expect(workspaceEvents.subscriberCount(NSWorkspace.activeSpaceDidChangeNotification) == 1)

        let frame = window.frame
        coordinator.pointerLocation = { CGPoint(x: frame.midX, y: frame.midY) }
        coordinator.appIsActive = { true }
        coordinator.hoverCardsEnabled = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.windowNumberAt = { _ in window.windowNumber }
        coordinator.ownWindows = { [(number: window.windowNumber, frame: frame)] }
        coordinator.pointerMoved()
        try #require(coordinator.machine.activeTarget?.id == HoverTargetID("tab"), "no pending card: \(coordinator.machine.phase)")

        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        #expect(coordinator.machine.activeTarget == nil, "a Space change left the card pending")
    }

    @Test func aCoordinatorWithoutTheAppsFanOutsSubscribesToNothing() {
        let window = InputTapTestEvents.window()
        defer { window.orderOut(nil) }
        let coordinator = HoverCardCoordinator(clock: ManualClock())
        let source = Source(window: window)
        coordinator.register(source)
        defer { coordinator.unregister(source) }
        #expect(coordinator.appWatches.isEmpty, "a coordinator with no fan-outs subscribed")
    }
}
