import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing
import CmuxNextDesignTokens

/// Content moving under a still pointer (a tab strip relayout, a list scroll) asks the window server which window
/// is on top at most once per display frame: each relayout asked again (a WindowServer round trip,
/// SLSConnectionSynchronizeSLSCATransaction: 39-88 ms of drag.tab_to_pane's light-session stalls, macOS 26/27).
/// The answer lives one frame only, never until a notification of this app: another app's window or a non-key
/// panel brought forward under a still pointer posts nothing here (review 1 of 5a069bc6996).
@MainActor @Suite(.serialized, .closesItsWindows) struct HoverCardWindowQueryTests {
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

    /// Another app's window or cmux's own non-key panel (a HUD) ordered front under a still pointer posts no
    /// notification this coordinator sees: the next frame asks the window server again and gets the panel, so the
    /// source under it no longer bridges (no card opens through the panel).
    @Test func aNonKeyPanelOrderedFrontUnderAStillPointerIsSeenTheNextFrame() {
        _ = NSApplication.shared
        let saved = WindowPlacement.noActivate
        WindowPlacement.noActivate = false
        defer { WindowPlacement.noActivate = saved }
        let main = window(CGRect(x: 200, y: 200, width: 300, height: 100))
        defer { main.close() }
        let queries = Queries()
        let point = CGPoint(x: main.frame.midX, y: main.frame.midY)
        let coordinator = coordinator(main, queries: queries, pointer: { point })
        let panel = NSPanel(contentRect: main.frame.insetBy(dx: 20, dy: 20), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        var front = main.windowNumber
        coordinator.windowNumberAt = { _ in queries.count += 1; return front }
        let source = BridgingSource(window: main)
        coordinator.register(source)
        defer { coordinator.unregister(source) }
        #expect(coordinator.bridges(at: point), "the source's own window is on top: it bridges")

        panel.orderFrontRegardless()  // a non-key panel: no key, move or resize notification of the main window
        #expect(!panel.isKeyWindow)
        // The window server's answer: the panel's number. A headless fleet run can give both windows the same
        // number (no window device), so the answer then names any number that is not the source's window.
        front = panel.windowNumber != main.windowNumber ? panel.windowNumber : main.windowNumber &+ 1
        #expect(coordinator.bridges(at: point), "the same frame keeps its one answer")
        queries.now += 1.0 / 60
        #expect(!coordinator.bridges(at: point), "a card would open through the panel ordered front a frame ago")
        #expect(queries.count == 2)
    }

    /// A source in `window` whose targets bridge every point (`bridges(at:)` then depends only on the top window).
    private final class BridgingSource: HoverCardSource {
        let window: NSWindow
        init(window: NSWindow) { self.window = window }
        var hoverCardWindow: NSWindow? { window }
        func hoverCardHit(at screenPoint: CGPoint) -> HoverCardHit? { nil }
        func hoverCardAnchor(for id: HoverTargetID) -> CGRect? { nil }
        func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? { nil }
        func hoverCardActivated(_ id: HoverTargetID) {}
        func hoverCardDeactivated(_ id: HoverTargetID) {}
        func hoverCardBridges(at screenPoint: CGPoint) -> Bool { true }
    }
}
