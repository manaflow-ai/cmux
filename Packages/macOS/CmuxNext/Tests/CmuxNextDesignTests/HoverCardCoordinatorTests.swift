import AppKit
import Testing
@testable import CmuxNextDesign

/// The coordinator turns the world into machine events: one app-wide card
/// across every source and window, and hit tests of a still pointer after
/// geometry changes.
@MainActor @Suite struct HoverCardCoordinatorTests {
    final class FakeSource: HoverCardSource {
        let window: NSWindow
        /// Target rects in screen coordinates.
        var targets: [HoverTargetID: CGRect] = [:]
        var activated: [HoverTargetID] = []
        var deactivated: [HoverTargetID] = []
        init(window: NSWindow) { self.window = window }
        var hoverCardWindow: NSWindow? { window }
        func hoverCardHit(at point: CGPoint) -> HoverCardHit? {
            guard let (id, rect) = targets.first(where: { $0.value.contains(point) }) else { return nil }
            return HoverCardHit(target: HoverTarget(id: id, window: window.windowNumber, delay: .seconds(30)), anchor: rect)
        }
        func hoverCardAnchor(for id: HoverTargetID) -> CGRect? { targets[id] }
        func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? { nil }
        func hoverCardActivated(_ id: HoverTargetID) { activated.append(id) }
        func hoverCardDeactivated(_ id: HoverTargetID) { deactivated.append(id) }
    }

    /// A window with a fixed number. A test process without a window
    /// server session (a fleet ci-step over SSH) gives every real window
    /// number 0, so the hit test could not tell the two sources apart and
    /// the result followed the dictionary's per-process hash order.
    final class NumberedWindow: NSWindow {
        var number = 0
        override var windowNumber: Int { number }
    }

    static func window(number: Int) -> NSWindow {
        let window = NumberedWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.number = number
        return window
    }

    final class Harness {
        let coordinator = HoverCardCoordinator()
        let a = FakeSource(window: window(number: 101))
        let b = FakeSource(window: window(number: 102))
        var pointer = CGPoint.zero
        var topWindow = 0
        init() {
            coordinator.pointerLocation = { [unowned self] in self.pointer }
            coordinator.windowNumberAt = { [unowned self] _ in self.topWindow }
            coordinator.appIsActive = { true }
            coordinator.register(a)
            coordinator.register(b)
            a.targets = [HoverTargetID("tab:1"): CGRect(x: 0, y: 0, width: 100, height: 20),
                         HoverTargetID("tab:2"): CGRect(x: 100, y: 0, width: 100, height: 20)]
            b.targets = [HoverTargetID("ws:x"): CGRect(x: 0, y: 0, width: 100, height: 20)]
        }
    }

    @Test func oneCardAcrossSourcesAndWindows() {
        let h = Harness()
        h.topWindow = h.a.window.windowNumber
        h.pointer = CGPoint(x: 10, y: 10)
        h.coordinator.pointerMoved()
        #expect(h.coordinator.machine.activeTarget?.id == HoverTargetID("tab:1"))
        // The same screen point in the other window (on top now): its target replaces it.
        h.topWindow = h.b.window.windowNumber
        h.coordinator.pointerMoved()
        #expect(h.coordinator.machine.activeTarget?.id == HoverTargetID("ws:x"))
        #expect(h.a.deactivated == [HoverTargetID("tab:1")], "the first source's card ended before the second began")
        #expect(h.b.activated == [HoverTargetID("ws:x")])
    }

    @Test func contentMovingUnderAStillPointerRetargets() {
        let h = Harness()
        h.topWindow = h.a.window.windowNumber
        h.pointer = CGPoint(x: 10, y: 10)
        h.coordinator.pointerMoved()
        #expect(h.coordinator.machine.activeTarget?.id == HoverTargetID("tab:1"))
        // The strip scrolls: tab 2 now sits under the pointer.
        h.a.targets = [HoverTargetID("tab:1"): CGRect(x: -100, y: 0, width: 100, height: 20),
                       HoverTargetID("tab:2"): CGRect(x: 0, y: 0, width: 100, height: 20)]
        h.coordinator.geometryChanged(in: h.a.window)
        #expect(h.coordinator.machine.activeTarget?.id == HoverTargetID("tab:2"))
        // Everything scrolls away from the pointer: no card.
        h.a.targets = [:]
        h.coordinator.geometryChanged(in: h.a.window)
        #expect(h.coordinator.machine.activeTarget == nil)
    }

    @Test func geometryChangesElsewhereCostNothingWhenIdle() {
        let h = Harness()
        h.pointer = CGPoint(x: 5000, y: 5000)
        let before = h.coordinator.eventCount
        h.coordinator.geometryChanged(in: h.a.window)
        #expect(h.coordinator.eventCount == before, "the pointer is outside the window: no hit test, no event")
    }

    @Test func aSourceGoingAwayEndsItsCardOnly() {
        let h = Harness()
        h.topWindow = h.a.window.windowNumber
        h.pointer = CGPoint(x: 10, y: 10)
        h.coordinator.pointerMoved()
        h.coordinator.unregister(h.b)
        #expect(h.coordinator.machine.activeTarget?.id == HoverTargetID("tab:1"))
        h.coordinator.unregister(h.a)
        #expect(h.coordinator.machine.activeTarget == nil)
    }

    @Test func keyAndDragEndInIdleAndAStillPointerDoesNotRestart() {
        let h = Harness()
        h.topWindow = h.a.window.windowNumber
        h.pointer = CGPoint(x: 10, y: 10)
        h.coordinator.pointerMoved()
        h.coordinator.dismiss(.keyDown)
        #expect(h.coordinator.machine.phase == .idle)
        h.coordinator.geometryChanged(in: h.a.window)
        #expect(h.coordinator.machine.phase == .idle, "quiet until the pointer moves")
        h.coordinator.suppress(.drag)
        h.coordinator.pointerMoved()
        #expect(h.coordinator.machine.phase == .idle)
        h.coordinator.unsuppress(.drag)
        h.coordinator.pointerMoved()
        #expect(h.coordinator.machine.activeTarget?.id == HoverTargetID("tab:1"))
    }

    @Test func sidebarHideCannotRearmOnAStillPointerTargetChange() {
        let h = Harness()
        h.topWindow = h.a.window.windowNumber
        h.pointer = CGPoint(x: 10, y: 10)
        h.coordinator.pointerMoved()
        h.coordinator.suppress(.sidebarHide)
        h.a.targets = [HoverTargetID("tab:2"): CGRect(x: 0, y: 0, width: 100, height: 20)]
        h.coordinator.geometryChanged(in: h.a.window)
        #expect(h.coordinator.machine.phase == .idle)
        #expect(h.coordinator.machine.activeTarget == nil)
        h.coordinator.unsuppress(.sidebarHide)
    }

    @Test func noCardWindowExistsUntilACardShows() {
        let h = Harness()
        h.topWindow = h.a.window.windowNumber
        h.pointer = CGPoint(x: 10, y: 10)
        h.coordinator.pointerMoved()
        #expect(h.coordinator.report["card_windows"] == "\(HoverCardPanel.liveInstances)")
        #expect(h.coordinator.singleCardViolations().isEmpty)
    }
}
