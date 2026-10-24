import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Content moving under a still pointer (a tab strip relayout, a list scroll, each frame of a tab-close slide, a
/// drop animation or a sidebar row animation) asks the window server which window is on top at most once: each
/// relayout asked again (a WindowServer round trip, SLSConnectionSynchronizeSLSCATransaction: 39-88 ms of
/// drag.tab_to_pane's light-session stalls, macOS 26/27, 8f96f40dce6). A cache that lives one display frame
/// misses on every frame of an animation (60 Hz frames are 16.7 ms apart; 120 Hz frames jitter past 8.3 ms), so
/// the answer holds until the pointer moves or a source window moves or resizes (review of cc58aba3e25). A pending
/// card's deadline asks again (`HoverCardDeadlineWindowTests`), so a window this app is never told about cannot
/// open a card through it.
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

    /// The frames of an animation under a still pointer, 60 Hz and 120 Hz with jitter, ask once in all; the
    /// pointer moving asks again, and so does a pointer event at the same point.
    @Test(arguments: [false, true])
    func anAnimationUnderAStillPointerAsksTheWindowServerOnce(noActivate: Bool) {
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

        // A tab-close slide at 60 Hz, then one at 120 Hz with each frame a little late (display link jitter).
        for _ in 0..<18 {
            queries.now += 1.0 / 60
            coordinator.geometryChanged(in: main)
        }
        for frame in 0..<36 {
            queries.now += 1.0 / 120 + (frame.isMultiple(of: 2) ? 0.000_3 : -0.000_1)
            coordinator.geometryChanged(in: main)
        }
        #expect(queries.count == 1, "\(queries.count) window server queries for 54 animation frames under a still pointer")

        point.x += 5  // the pointer moved: ask again
        coordinator.geometryChanged(in: main)
        #expect(queries.count == 2)

        coordinator.pointerMoved(to: point)  // a pointer event decides a card: it asks again, even at the same point
        #expect(queries.count == 3, "a pointer event reused the answer from before it")
    }

    /// A source window that resizes under a still pointer posts its resize, the last re-hit-test there: that one
    /// asks the window server again, with no time passing.
    @Test func aSourceWindowResizedUnderAStillPointerAsksAgain() {
        _ = NSApplication.shared
        let saved = WindowPlacement.noActivate
        WindowPlacement.noActivate = false
        defer { WindowPlacement.noActivate = saved }
        let main = window(CGRect(x: 200, y: 200, width: 300, height: 100))
        defer { main.close() }
        let queries = Queries()
        let point = CGPoint(x: main.frame.midX, y: main.frame.midY)
        let coordinator = coordinator(main, queries: queries, pointer: { point })
        let source = Source(window: main)
        coordinator.register(source)
        defer { coordinator.unregister(source) }
        coordinator.geometryChanged(in: main)
        #expect(queries.count == 1)

        main.setContentSize(NSSize(width: 320, height: 100))  // a window changed: AppKit posts its resize
        #expect(queries.count == 2, "the resize re-hit-tested with the top window from before it")
    }
}
