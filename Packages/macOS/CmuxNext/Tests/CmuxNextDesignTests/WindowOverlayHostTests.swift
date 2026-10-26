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
}
