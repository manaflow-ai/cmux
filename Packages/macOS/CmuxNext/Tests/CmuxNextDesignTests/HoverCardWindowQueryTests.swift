import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Content moving under a still pointer (a tab strip relayout, a list scroll) asks the window server which window
/// is on top at most once per display frame: each relayout asked again (a WindowServer round trip,
/// SLSConnectionSynchronizeSLSCATransaction: 39-88 ms of drag.tab_to_pane's light-session stalls, macOS 26/27).
/// The answer lives one frame only, never until a notification of this app: another app's window or a non-key
/// panel brought forward under a still pointer posts nothing here (review 1 of 5a069bc6996).
@MainActor @Suite(.serialized) struct HoverCardWindowQueryTests {
    private func window(_ frame: CGRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    private final class Queries {
        var count = 0
        /// The coordinator's clock (seconds).
        var now: CFTimeInterval = 100
    }

    /// A source in `window` with no targets: registering it installs the coordinator's window observers.
    private final class Source: HoverCardSource {
        let window: NSWindow
        init(window: NSWindow) { self.window = window }
        var hoverCardWindow: NSWindow? { window }
        func hoverCardHit(at screenPoint: CGPoint) -> HoverCardHit? { nil }
        func hoverCardAnchor(for id: HoverTargetID) -> CGRect? { nil }
        func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? { nil }
        func hoverCardActivated(_ id: HoverTargetID) {}
        func hoverCardDeactivated(_ id: HoverTargetID) {}
    }

    private func coordinator(_ main: NSWindow, queries: Queries, pointer: @escaping () -> CGPoint) -> HoverCardCoordinator {
        let coordinator = HoverCardCoordinator()
        coordinator.pointerLocation = pointer
        coordinator.appIsActive = { true }
        coordinator.hoverCardsEnabled = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.windowNumberAt = { _ in queries.count += 1; return main.windowNumber }
        coordinator.now = { queries.now }
        coordinator.ownWindows = { queries.count += 1; return [(number: main.windowNumber, frame: main.frame)] }
        return coordinator
    }

    @Test(arguments: [false, true])
    func relayoutsUnderAStillPointerAskTheWindowServerOnce(noActivate: Bool) {
        _ = NSApplication.shared
        let saved = WindowPlacement.noActivate
        WindowPlacement.noActivate = noActivate
        defer { WindowPlacement.noActivate = saved }
        let main = window(CGRect(x: 200, y: 200, width: 300, height: 100))
        defer { main.close() }
        let queries = Queries()
        var point = CGPoint(x: main.frame.midX, y: main.frame.midY)
        let coordinator = coordinator(main, queries: queries, pointer: { point })
        let source = Source(window: main)
        coordinator.register(source)
        defer { coordinator.unregister(source) }
        for _ in 0..<10 { coordinator.geometryChanged(in: main) }
        #expect(queries.count == 1, "\(queries.count) window server queries for 10 relayouts in one frame")

        // The next frame asks again with no notification at all: another app's window may be on top now.
        queries.now += 1.0 / 60
        coordinator.geometryChanged(in: main)
        #expect(queries.count == 2, "a still pointer kept the top window past its frame")

        point.x += 5  // the pointer moved: ask again in the same frame
        coordinator.geometryChanged(in: main)
        #expect(queries.count == 3)
    }
}
