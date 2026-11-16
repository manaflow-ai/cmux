@testable import CmuxNextDesign
import AppKit
import CmuxNextDesignTokens
import CmuxNextTestSupport
import Testing

/// Leo, 2026-11-01: "i need these hover previews to appear a hell of a lot faster than they do now".
/// A probe on a fresh Nightly saw no sidebar hover card in 20 of 20 hovers. One cause: a window's
/// hidden sidebar suppressed cards on the one app-wide coordinator (`suppress(.sidebarHide)`), so
/// any window with its sidebar hidden (a background or off-screen one too) stopped every card in
/// every window; two hidden windows and one shown cleared it while the other stayed hidden; and a
/// window closed while hidden stopped every card until relaunch. A hidden sidebar stops only its own
/// window's cards, and a closing window releases its hold.
@MainActor @Suite(.closesItsWindows, .serialized)
struct HoverCardSidebarHidePerWindowTests {
    /// A source covering its whole window with one target.
    @MainActor
    private final class Source: HoverCardSource {
        let window: NSWindow
        let id: HoverTargetID
        init(window: NSWindow, id: String) {
            self.window = window
            self.id = HoverTargetID(id)
        }
        var target: HoverTarget { HoverTarget(id: id, window: window.windowNumber, delay: .seconds(30), leave: .hides(reshow: .milliseconds(300))) }
        var hoverCardWindow: NSWindow? { window }
        func hoverCardHit(at point: CGPoint) -> HoverCardHit? {
            window.frame.contains(point) ? HoverCardHit(target: target, anchor: window.frame) : nil
        }
        func hoverCardAnchor(for id: HoverTargetID) -> CGRect? { id == self.id ? window.frame : nil }
        func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? {
            HoverCardBody(view: NSTextField(labelWithString: id.rawValue), placement: .below, themeAnchor: nil) {}
        }
        func hoverCardActivated(_: HoverTargetID) {}
        func hoverCardDeactivated(_: HoverTargetID) {}
    }

    private final class Pointer { var point = CGPoint.zero }

    @MainActor
    private struct Fixture {
        let a: NSWindow
        let b: NSWindow
        let sourceA: Source
        let sourceB: Source
        let pointer: Pointer
        let coordinator: HoverCardCoordinator

        func move(to window: NSWindow) {
            pointer.point = CGPoint(x: window.frame.midX, y: window.frame.midY)
            coordinator.pointerMoved(to: pointer.point)
        }

        /// The target whose card waits for its delay, nil while none does.
        var pending: HoverTargetID? {
            if case .pending(let target, _) = coordinator.machine.phase { return target.id }
            return nil
        }

        func close() {
            coordinator.dismiss(.action)
            coordinator.unregister(sourceA)
            coordinator.unregister(sourceB)
            ([coordinator.panel] + coordinator.retiring).forEach { $0?.closeAfterTest() }
            a.close()
            b.close()
        }
    }

    private static func window(_ frame: CGRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    private func fixture() -> Fixture {
        _ = NSApplication.shared
        let a = Self.window(CGRect(x: 100, y: 100, width: 300, height: 200))
        let b = Self.window(CGRect(x: 600, y: 100, width: 300, height: 200))
        let pointer = Pointer()
        let coordinator = HoverCardCoordinator()
        coordinator.pointerLocation = { pointer.point }
        coordinator.appIsActive = { true }
        coordinator.hoverCardsEnabled = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.windowNumberAt = { point in [a, b].first { $0.frame.contains(point) }?.windowNumber }
        coordinator.ownWindows = { [a, b].map { (number: $0.windowNumber, frame: $0.frame) } }
        let sourceA = Source(window: a, id: "ws:a")
        let sourceB = Source(window: b, id: "ws:b")
        coordinator.register(sourceA)
        coordinator.register(sourceB)
        return Fixture(a: a, b: b, sourceA: sourceA, sourceB: sourceB, pointer: pointer, coordinator: coordinator)
    }

    @Test func oneWindowsHiddenSidebarLeavesAnotherWindowsCards() {
        let f = fixture()
        defer { f.close() }
        f.coordinator.sidebarHidden(true, in: f.a)
        f.move(to: f.b)
        #expect(f.pending == HoverTargetID("ws:b"), "window A's hidden sidebar stopped window B's card")
        f.move(to: f.a)
        #expect(f.pending == nil, "window A's hidden sidebar still gives its own targets a card")
        #expect(f.coordinator.machine.suppressions.isEmpty, "a hidden sidebar is no app-wide suppression")
    }

    @Test func hidingASidebarEndsOnlyThatWindowsCard() {
        let f = fixture()
        defer { f.close() }
        f.move(to: f.b)
        #expect(f.pending == HoverTargetID("ws:b"))
        f.coordinator.sidebarHidden(true, in: f.a)
        #expect(f.pending == HoverTargetID("ws:b"), "window A hiding its sidebar ended window B's card")

        f.coordinator.sidebarHidden(true, in: f.b)
        #expect(f.pending == nil, "window B hiding its sidebar kept its own card")
    }

    @Test func showingOneOfTwoHiddenSidebarsKeepsTheOtherHidden() {
        let f = fixture()
        defer { f.close() }
        f.coordinator.sidebarHidden(true, in: f.a)
        f.coordinator.sidebarHidden(true, in: f.b)
        f.coordinator.sidebarHidden(false, in: f.a)
        f.move(to: f.b)
        #expect(f.pending == nil, "showing window A's sidebar released window B's hidden one")
        f.move(to: f.a)
        #expect(f.pending == HoverTargetID("ws:a"))
    }

    @Test func aHiddenWindowPinsNoCard() {
        let f = fixture()
        defer { f.close() }
        f.coordinator.sidebarHidden(true, in: f.a)
        f.coordinator.pin(f.sourceA.target, from: f.sourceA)
        #expect(f.coordinator.machine.activeTarget == nil, "a window with its sidebar hidden pinned a card")
    }

    @Test func aWindowTornDownWhileHiddenLeavesNoSuppression() {
        let f = fixture()
        defer { f.close() }
        f.coordinator.sidebarHidden(true, in: f.a)
        f.coordinator.windowClosed(f.a)
        #expect(f.coordinator.hiddenSidebars.isEmpty, "a closed window still holds its hidden sidebar")
        #expect(f.coordinator.report["hidden_sidebars"] == "0")
        f.move(to: f.b)
        #expect(f.pending == HoverTargetID("ws:b"))
        f.move(to: f.a)
        #expect(f.pending == HoverTargetID("ws:a"), "window A's hold outlived its teardown")
    }
}
