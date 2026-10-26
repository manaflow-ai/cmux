import AppKit
@testable import CmuxNextDesign
import CmuxNextInput
import Testing

/// A window's overlay host listens on the app's one input tap, not AppKit event monitors
/// (p04-input-013): an overlay that dismisses on Escape holds an intercept of order `.modal`, which
/// runs before every popup's and consumes the Escape it takes; an interactive overlay keeps a pointer
/// observer for the panel's mouse routing; with no overlay left, the host holds no subscription.
@MainActor @Suite(.serialized) struct WindowOverlayHostTests {
    final class Log {
        var popupHeard = 0
    }

    private static func host(_ events: InputTapTestEvents, window: NSWindow) -> WindowOverlayHost {
        let host = WindowOverlayHost.host(for: window)
        host.inputTap = events.tap
        return host
    }

    private static func popover() -> NSView {
        NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
    }

    @Test func anEscapeOverlayTakesEscapeBeforeAPopupAndUnsubscribesWhenItGoes() throws {
        let events = InputTapTestEvents()
        let window = InputTapTestEvents.window()
        let log = Log()
        // A popup's Escape intercept subscribed first still runs after the overlay's (the order table).
        let popup = events.tap.subscribe(class: .key, phase: .intercept(order: .popup)) { _ in
            log.popupHeard += 1
            return .pass
        }
        let host = Self.host(events, window: window)
        defer {
            host.tearDown()
            window.orderOut(nil)
        }
        let handle = host.present(Self.popover(), options: OverlayOptions(kind: .popover, anchor: NSRect(x: 40, y: 40, width: 20, height: 20),
                                                                          dismissOnEscape: true))
        #expect(events.tap.subscriberCount(.key, stage: .intercept) == 2, "no Escape intercept while the overlay shows")

        #expect(!events.dispatch(try InputTapTestEvents.key(.keyDown, keyCode: 53, in: window, modifiers: .command)),
                "a Command-Escape was taken")
        #expect(!handle.isDismissed)
        #expect(!events.dispatch(try InputTapTestEvents.key(.keyUp, keyCode: 53, in: window)))
        #expect(log.popupHeard == 2, "the popup's intercept missed the keys the overlay passed")

        #expect(events.dispatch(try InputTapTestEvents.key(.keyDown, keyCode: 53, in: window)), "the overlay's Escape went on")
        #expect(handle.isDismissed, "Escape did not dismiss the overlay")
        #expect(log.popupHeard == 2, "the popup's intercept heard the Escape the overlay consumed")
        #expect(events.tap.subscriberCount(.key, stage: .intercept) == 1, "the overlay's Escape intercept outlived it")
        withExtendedLifetime(popup) {}
    }

    @Test func anInteractiveOverlayObservesThePointerUntilItGoes() throws {
        let events = InputTapTestEvents()
        let window = InputTapTestEvents.window()
        let host = Self.host(events, window: window)
        defer {
            host.tearDown()
            window.orderOut(nil)
        }
        let handle = host.present(Self.popover(), options: OverlayOptions(kind: .popover, anchor: NSRect(x: 40, y: 40, width: 20, height: 20)))
        #expect(events.tap.subscriberCount(.pointerMove, stage: .observe) == 1, "no mouse routing observer for an interactive overlay")
        #expect(events.tap.subscriberCount(.button, stage: .observe) == 1)
        #expect(events.tap.subscriberCount(.drag, stage: .observe) == 1)
        #expect(events.tap.subscriberCount(.tracking, stage: .observe) == 1)
        // An observer: a click passes on to AppKit.
        #expect(!events.dispatch(try InputTapTestEvents.mouse(.leftMouseDown, in: window)))
        handle.dismiss()
        #expect(events.subscriptions == 0, "the host still listens with no overlay")
    }

    /// The parent window takes no mouse moves, so the pointer can reach an interactive overlay with only
    /// tracking-area enters and exits on the way: they route the mouse as a move does, so the panel takes
    /// the first click on the overlay and lets go once the pointer leaves it.
    @Test func trackingAreaEdgesRouteTheMouseWithNoMove() throws {
        let events = InputTapTestEvents()
        let window = InputTapTestEvents.window()
        let host = Self.host(events, window: window)
        defer {
            host.tearDown()
            window.orderOut(nil)
        }
        let away = NSPoint(x: -10_000, y: -10_000)
        host.pointerLocation = { away }
        let handle = host.present(Self.popover(), options: OverlayOptions(kind: .popover, anchor: NSRect(x: 40, y: 40, width: 20, height: 20)))
        defer { handle.dismiss() }
        #expect(host.panel.ignoresMouseEvents, "the panel took the mouse with the pointer away from the overlay")
        let region = try #require(host.interactiveRegions().first, "the popover has no interactive region")
        let onOverlay = host.panel.convertPoint(toScreen: NSPoint(x: region.midX, y: region.midY))

        host.pointerLocation = { onOverlay }
        events.dispatch(try InputTapTestEvents.tracking(.mouseEntered, in: window))
        #expect(!host.panel.ignoresMouseEvents, "an enter onto the overlay left the panel ignoring the mouse")
        host.pointerLocation = { away }
        events.dispatch(try InputTapTestEvents.tracking(.mouseExited, in: window))
        #expect(host.panel.ignoresMouseEvents, "an exit off the overlay left the panel taking the mouse")
    }

    // MARK: Routing once per frame (feature `pointerFrameHover`, p04-input-036)

    /// A popover's host whose pointer the test moves, counting each routing (one pointer read each).
    @MainActor final class Routing {
        static let away = NSPoint(x: -10_000, y: -10_000)
        let events: InputTapTestEvents
        let window: NSWindow
        let frames: PointerFrameTestRig
        let host: WindowOverlayHost
        let handle: OverlayHandle
        let onOverlay: NSPoint
        var away: NSPoint { Self.away }
        var pointer = Routing.away
        var routes = 0

        init(frameInput: Bool = true) throws {
            let events = InputTapTestEvents()
            let window = InputTapTestEvents.window()
            let frames = PointerFrameTestRig()
            let host = WindowOverlayHostTests.host(events, window: window)
            if frameInput { host.hoverFrames = frames.coalescers }
            host.pointerLocation = { Routing.away }
            let handle = host.present(WindowOverlayHostTests.popover(),
                                      options: OverlayOptions(kind: .popover, anchor: NSRect(x: 40, y: 40, width: 20, height: 20)))
            let region = try #require(host.interactiveRegions().first, "the popover has no interactive region")
            self.events = events
            self.window = window
            self.frames = frames
            self.host = host
            self.handle = handle
            onOverlay = host.panel.convertPoint(toScreen: NSPoint(x: region.midX, y: region.midY))
            host.pointerLocation = { [weak self] in
                guard let self else { return .zero }
                routes += 1
                return pointer
            }
        }

        /// A move seen by the tap with the pointer at `point`.
        func move(to point: NSPoint) throws {
            pointer = point
            events.dispatch(try InputTapTestEvents.mouse(.mouseMoved, in: window))
        }

        func close() {
            handle.dismiss()
            host.tearDown()
            frames.close()
            window.orderOut(nil)
        }
    }

    /// Eight moves in one frame route the mouse twice: the leading move in its own turn, the other
    /// seven once at the frame, at the pointer then, so the panel takes the mouse over the overlay.
    @Test func eightMovesInOneFrameRouteTheMouseTwiceAtTheLatestPoint() throws {
        let routing = try Routing()
        defer { routing.close() }
        for step in 0..<8 { try routing.move(to: step.isMultiple(of: 2) ? routing.away : routing.onOverlay) }
        #expect(routing.routes == 1, "only the leading move routes before the frame")
        #expect(routing.host.panel.ignoresMouseEvents, "the leading move was away from the overlay")
        #expect(routing.frames.coalescer.hasPending)
        routing.frames.frame()
        #expect(routing.routes == 2, "the frame routed the seven waiting moves once")
        #expect(!routing.host.panel.ignoresMouseEvents, "the frame did not route at the latest pointer, on the overlay")
        #expect(routing.host.routingMoves?.maxDeliveriesPerFrame == 2)
        #expect(!routing.frames.coalescer.hasPending)
    }

    /// A lone move after an idle frame routes in its own turn: the frame-aligned path adds no wait.
    @Test func aSingleMoveAfterAnIdleFrameRoutesInTheSameTurn() throws {
        let routing = try Routing()
        defer { routing.close() }
        try routing.move(to: routing.onOverlay)
        #expect(routing.routes == 1)
        #expect(!routing.host.panel.ignoresMouseEvents)
        #expect(!routing.frames.coalescer.hasPending, "nothing waits for the frame")
    }

    /// A tracking-area edge is discrete: it lands the waiting moves now, once, and the frame after it
    /// has nothing left to route.
    @Test func anEdgeLandsTheWaitingMovesOnce() throws {
        let routing = try Routing()
        defer { routing.close() }
        try routing.move(to: routing.away)
        try routing.move(to: routing.onOverlay)
        #expect(routing.routes == 1)
        routing.events.dispatch(try InputTapTestEvents.tracking(.mouseEntered, in: routing.window))
        #expect(routing.routes == 2, "the enter routed apart from the moves it landed")
        #expect(!routing.host.panel.ignoresMouseEvents)
        #expect(!routing.frames.coalescer.hasPending)
        routing.frames.frame()
        #expect(routing.routes == 2, "the frame routed moves the enter had landed")
    }

    /// The tap and the panel's own `sendEvent` both hand over a move on the panel: it routes once.
    @Test func aMoveOnThePanelRoutesOnceThroughTheTapAndThePanel() throws {
        let routing = try Routing(frameInput: false)
        defer { routing.close() }
        routing.pointer = routing.onOverlay
        let move = try InputTapTestEvents.mouse(.mouseMoved, in: routing.host.panel)
        routing.events.dispatch(move)
        #expect(!routing.host.panelMouseEvent(move), "a move is never the panel's to take")
        #expect(routing.routes == 1)
    }

    /// With the feature off every move routes, as before.
    @Test func withoutFramesEachMoveRoutes() throws {
        let routing = try Routing(frameInput: false)
        defer { routing.close() }
        for step in 0..<8 { try routing.move(to: step.isMultiple(of: 2) ? routing.away : routing.onOverlay) }
        #expect(routing.routes == 8)
        #expect(!routing.host.panel.ignoresMouseEvents)
        #expect(routing.host.routingMoves == nil)
    }
}
