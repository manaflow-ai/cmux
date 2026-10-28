import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextInput
import Testing

/// A window's overlay host listens on the app's one input tap, not AppKit event monitors:
/// an overlay that dismisses on Escape holds an intercept of order `.modal`, which
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

    // MARK: Clicks route per event, the tag hover once per frame (feature `pointerFrameHover`)

    final class Tags: AgentCursorTagSource {
        var tags: [AgentCursorTagTarget] = [
            AgentCursorTagTarget(id: "s1", frame: CGRect(x: 100, y: 50, width: 120, height: 22),
                                 label: "a201 · cursor-gallery", help: "Go to cursor-gallery"),
        ]
        var hovered: [String?] = []
        func agentCursorTags() -> [AgentCursorTagTarget] { tags }
        func pressAgentCursorTag(_ id: String) {}
        func hoverAgentCursorTag(_ id: String?) { hovered.append(id) }
    }

    final class Seen {
        var panelTookMouse: Bool?
    }

    /// A host whose pointer the test moves (`pointer`, screen coordinates), with a popover or agent cursor
    /// tags in the panel, counting each pointer read.
    @MainActor final class Routing {
        enum Content { case popover, tags }
        static let away = NSPoint(x: -10_000, y: -10_000)
        let events: InputTapTestEvents
        let window: NSWindow
        let frames: PointerFrameTestRig
        let host: WindowOverlayHost
        let tags = Tags()
        private var handle: OverlayHandle?
        /// A screen point on the popover or on the tag.
        private(set) var onOverlay = Routing.away
        var away: NSPoint { Self.away }
        var pointer = Routing.away
        var reads = 0

        init(_ content: Content, frameInput: Bool = true, perWindow: Bool = false) throws {
            let events = InputTapTestEvents()
            let window = InputTapTestEvents.window()
            let frames = PointerFrameTestRig(perWindow: perWindow)
            let host = WindowOverlayHostTests.host(events, window: window)
            if frameInput { host.hoverFrames = frames.coalescers }
            host.pointerLocation = { Routing.away }
            self.events = events
            self.window = window
            self.frames = frames
            self.host = host
            switch content {
            case .popover:
                handle = host.present(WindowOverlayHostTests.popover(),
                                      options: OverlayOptions(kind: .popover, anchor: NSRect(x: 40, y: 40, width: 20, height: 20)))
                let region = try #require(host.interactiveRegions().first, "the popover has no interactive region")
                onOverlay = host.panel.convertPoint(toScreen: NSPoint(x: region.midX, y: region.midY))
            case .tags:
                host.agentCursorTags = tags
                _ = host.agentCursorLayer
                host.setPlanesWantPanel(true)
                host.agentCursorTagsDidChange()
                let carrier = try #require(host.agentCursorCarrier)
                try #require(carrier.window === host.panel, "the tags do not draw in the panel")
                try #require(host.mouseRouting != nil, "nothing routes the mouse over the tags")
                onOverlay = host.panel.convertPoint(toScreen: carrier.convert(NSPoint(x: 150, y: carrier.bounds.height - 61), to: nil))
            }
            host.pointerLocation = { [weak self] in
                guard let self else { return .zero }
                reads += 1
                return pointer
            }
        }

        /// A move seen by the tap with the pointer at `point`; `onPanel` addresses it to the panel.
        @discardableResult
        func move(to point: NSPoint, onPanel: Bool = false) throws -> NSEvent {
            pointer = point
            let event = try InputTapTestEvents.mouse(.mouseMoved, in: onPanel ? host.panel : window)
            events.dispatch(event)
            return event
        }

        /// The window server would give the panel a click now.
        var panelTakesMouse: Bool { !host.panel.ignoresMouseEvents }

        func close() {
            handle?.dismiss()
            host.agentCursorTags = nil
            host.setPlanesWantPanel(false)
            host.tearDown()
            frames.close()
            window.orderOut(nil)
        }
    }

    /// Every move routes the panel's clicks in its own turn, with frame-aligned hover on: the window
    /// server picks a click's window from `ignoresMouseEvents` before any app code runs.
    @Test func everyMoveRoutesClicksInItsOwnTurn() throws {
        let routing = try Routing(.popover)
        defer { routing.close() }
        for step in 0..<8 {
            let on = !step.isMultiple(of: 2)
            try routing.move(to: on ? routing.onOverlay : routing.away)
            #expect(routing.panelTakesMouse == on, "move \(step) left the click routing behind the pointer")
        }
        #expect(routing.reads == 8)
        #expect(routing.host.tagHoverMoves == nil, "no tag shows: nothing waits for the frame")
        #expect(!routing.frames.coalescer.hasPending)
    }

    /// A move off the overlay, a move onto a tag, then a press before the frame: the panel already takes
    /// the press (it went through to the page while the routing waited for the frame).
    @Test func aPressBeforeTheFrameFindsThePanelTakingTheMouse() throws {
        let routing = try Routing(.tags)
        defer { routing.close() }
        let seen = Seen()
        let press = routing.events.tap.subscribe(class: .button) { [weak routing] _ in seen.panelTookMouse = routing?.panelTakesMouse }
        try routing.move(to: routing.away)
        try routing.move(to: routing.onOverlay)
        #expect(routing.host.tagHoverMoves?.hasPending == true, "the tag hover did not wait for the frame")
        routing.events.dispatch(try InputTapTestEvents.mouse(.leftMouseDown, in: routing.window))
        #expect(seen.panelTookMouse == true, "the press went through the tag to the page")
        withExtendedLifetime(press) {}
    }

    /// Eight moves in one frame over and off a tag: the clicks route on each, the tag is hover-tested
    /// twice (the leading move, then the frame at the latest pointer).
    @Test func eightMovesOverATagHoverTwiceAndRouteClicksEachTime() throws {
        let routing = try Routing(.tags)
        defer { routing.close() }
        let carrier = try #require(routing.host.agentCursorCarrier)
        let before = carrier.hoverChecks
        for step in 0..<8 {
            let on = !step.isMultiple(of: 2)
            try routing.move(to: on ? routing.onOverlay : routing.away)
            #expect(routing.panelTakesMouse == on, "move \(step) left the click routing behind the pointer")
        }
        #expect(carrier.hoverChecks - before == 1, "a move after the leading one hovered before the frame")
        #expect(routing.tags.hovered.isEmpty)
        routing.frames.frame()
        #expect(carrier.hoverChecks - before == 2)
        #expect(routing.tags.hovered == ["s1"], "the frame did not hover the tag under the latest pointer")
        #expect(routing.host.tagHoverMoves?.maxDeliveriesPerFrame == 2)
    }

    /// Each panel move reaches the tap's routing (the parent's coalescer) and the carrier's own tracking
    /// area (the panel's coalescer): the tag is hover-tested from one path, at most twice a frame.
    @Test func aPanelMoveHoversTheTagFromOnePath() throws {
        let routing = try Routing(.tags, perWindow: true)
        defer { routing.close() }
        let carrier = try #require(routing.host.agentCursorCarrier)
        let before = carrier.hoverChecks
        for step in 0..<8 {
            let event = try routing.move(to: step.isMultiple(of: 2) ? routing.away : routing.onOverlay, onPanel: true)
            carrier.mouseMoved(with: event)
        }
        #expect(!carrier.hoverMoves.hasPending, "the carrier queued moves the routing hovers")
        routing.frames.frame()
        #expect(carrier.hoverChecks - before == 2, "the tag was hover-tested \(carrier.hoverChecks - before) times in one frame")
        #expect(routing.tags.hovered == ["s1"])
    }

    /// A tracking-area edge is discrete: it lands the waiting tag hover now, once, and the frame after it
    /// has nothing left to hover.
    @Test func anEdgeLandsTheWaitingTagHoverOnce() throws {
        let routing = try Routing(.tags)
        defer { routing.close() }
        let carrier = try #require(routing.host.agentCursorCarrier)
        let before = carrier.hoverChecks
        try routing.move(to: routing.away)
        try routing.move(to: routing.onOverlay)
        #expect(carrier.hoverChecks - before == 1)
        routing.events.dispatch(try InputTapTestEvents.tracking(.mouseEntered, in: routing.window))
        #expect(carrier.hoverChecks - before == 2, "the enter hovered apart from the move it landed")
        #expect(routing.tags.hovered == ["s1"])
        #expect(routing.host.tagHoverMoves?.hasPending == false)
        routing.frames.frame()
        #expect(carrier.hoverChecks - before == 2, "the frame hovered a move the enter had landed")
    }

    /// The tap and the panel's own `sendEvent` both hand over a move on the panel: it routes once.
    @Test func aMoveOnThePanelRoutesOnceThroughTheTapAndThePanel() throws {
        let routing = try Routing(.popover, frameInput: false)
        defer { routing.close() }
        let move = try routing.move(to: routing.onOverlay, onPanel: true)
        #expect(!routing.host.panelMouseEvent(move), "a move is never the panel's to take")
        #expect(routing.reads == 1)
    }

    /// With the feature off every move routes and hovers, as before.
    @Test func withoutFramesEachMoveHoversTheTag() throws {
        let routing = try Routing(.tags, frameInput: false)
        defer { routing.close() }
        let carrier = try #require(routing.host.agentCursorCarrier)
        let before = carrier.hoverChecks
        for step in 0..<8 { try routing.move(to: step.isMultiple(of: 2) ? routing.away : routing.onOverlay) }
        #expect(carrier.hoverChecks - before == 8)
        #expect(routing.host.tagHoverMoves == nil)
        #expect(routing.panelTakesMouse)
    }
}
