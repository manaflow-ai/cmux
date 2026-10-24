import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Content moving under a still pointer (a tab strip relayout, a list scroll, each animation frame) asks the
/// window server which window is on top at most once: the answer holds until the pointer moves or a window
/// moves, resizes, closes, changes key, occlusion or Space. Each relayout asked again (a WindowServer round trip,
/// SLSConnectionSynchronizeSLSCATransaction: 39-88 ms of drag.tab_to_pane's light-session stalls, macOS 26/27).
@MainActor @Suite(.serialized) struct HoverCardWindowQueryTests {
    private func window(_ frame: CGRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    private final class Queries {
        var count = 0
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
        #expect(queries.count == 1, "\(queries.count) window server queries for 10 relayouts under a still pointer")

        point.x += 5  // the pointer moved: ask again
        coordinator.geometryChanged(in: main)
        #expect(queries.count == 2)

        main.setContentSize(NSSize(width: 320, height: 100))  // a window changed: AppKit posts its resize
        coordinator.geometryChanged(in: main)
        #expect(queries.count == 3)
    }
}
