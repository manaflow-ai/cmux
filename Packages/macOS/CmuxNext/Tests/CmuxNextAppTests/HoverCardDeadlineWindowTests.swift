import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// A pending card shows at its deadline only while its target's window is still on top under the pointer.
/// Another app's window, a cmux non-key panel (a HUD) or a browser's child window ordered over the target during
/// the hover delay posts no notification the hover cards see, and the pointer does not move, so nothing else
/// asks the window server again: the deadline showed the pending target with no new hit test, and the card opened
/// over the window that covered it (review of cc58aba3e25). The delay runs on a manual clock the test moves.
@MainActor @Suite(.serialized) struct HoverCardDeadlineWindowTests {
    /// One target, a tab-sized strip at the top of `window`, with a real card body.
    private final class Source: HoverCardSource {
        static let id = HoverTargetID("tab")
        let window: NSWindow
        let body = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        init(window: NSWindow) { self.window = window }
        var anchor: CGRect { CGRect(x: window.frame.minX + 20, y: window.frame.maxY - 40, width: 160, height: 30) }
        var hoverCardWindow: NSWindow? { window }
        func hoverCardHit(at screenPoint: CGPoint) -> HoverCardHit? {
            guard anchor.contains(screenPoint) else { return nil }
            let target = HoverTarget(id: Self.id, window: window.windowNumber, delay: .milliseconds(500))
            return HoverCardHit(target: target, anchor: anchor)
        }
        func hoverCardAnchor(for id: HoverTargetID) -> CGRect? { id == Self.id ? anchor : nil }
        func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? {
            id == Self.id ? HoverCardBody(view: body, placement: .below, themeAnchor: nil, applyTheme: {}) : nil
        }
        func hoverCardActivated(_ id: HoverTargetID) {}
        func hoverCardDeactivated(_ id: HoverTargetID) {}
    }

    /// Lets a deadline the clock reached reach the coordinator (the timer wakes off the main actor and hops
    /// back), waiting (bounded) until `done`.
    private static func settle(until done: () -> Bool) async throws {
        for _ in 0..<20 { await Task.yield() }
        for _ in 0..<500 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    private static func isPending(_ coordinator: HoverCardCoordinator) -> Bool {
        if case .pending = coordinator.machine.phase { return true }
        return false
    }

    /// The pointer rests on the target; during the delay a non-key panel is ordered over it (`covered`) or not.
    /// At the deadline the card shows only when nothing covers the target.
    @Test(arguments: [false, true])
    func aPendingCardShowsOnlyOverTheWindowStillOnTop(covered: Bool) async throws {
        _ = NSApplication.shared
        let saved = WindowPlacement.noActivate
        WindowPlacement.noActivate = false
        defer { WindowPlacement.noActivate = saved }
        let main = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 500, height: 200), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.orderFrontRegardless()
        defer { main.close() }
        let source = Source(window: main)
        let point = CGPoint(x: source.anchor.midX, y: source.anchor.midY)
        let clock = ManualClock()
        let coordinator = HoverCardCoordinator(clock: clock)
        coordinator.appIsActive = { true }
        coordinator.hoverCardsEnabled = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.pointerLocation = { point }
        // The window server's answer under the pointer: the source's window until something is ordered over it.
        var front = main.windowNumber
        coordinator.windowNumberAt = { _ in front }
        coordinator.register(source)
        defer {
            coordinator.dismiss(.action)
            coordinator.unregister(source)
        }

        coordinator.pointerMoved(to: point)
        try #require(Self.isPending(coordinator), "resting on the target started no card: \(coordinator.machine.phase)")
        try await clock.waitForSleeper()

        let panel = NSPanel(contentRect: source.anchor.insetBy(dx: -40, dy: -40), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        if covered {
            panel.orderFrontRegardless()  // a non-key panel: no notification of the source's window, no pointer move
            #expect(!panel.isKeyWindow)
            // A headless fleet run can give both windows the same number (no window device): the answer then names
            // any number that is not the source's window.
            front = panel.windowNumber != main.windowNumber ? panel.windowNumber : main.windowNumber &+ 1
        }

        clock.advance(by: .milliseconds(600))
        try await Self.settle(until: { !Self.isPending(coordinator) })
        #expect(!Self.isPending(coordinator), "the deadline never reached the coordinator")
        if covered {
            #expect(!coordinator.isShowing(Source.id), "the card opened over the panel ordered over its target during the delay")
            #expect(coordinator.machine.shownTarget == nil)
        } else {
            #expect(coordinator.isShowing(Source.id), "no card at the deadline with nothing over the target")
        }
    }
}
