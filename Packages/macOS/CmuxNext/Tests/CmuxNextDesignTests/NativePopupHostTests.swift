import AppKit
@testable import CmuxNextDesign
import CmuxNextInput
import Testing

/// The native popup host listens on the app's one input tap, not AppKit event monitors:
/// while the popup shows, a click outside it closes it and goes on, and Escape in it closes it and
/// stops there (an intercept of order `.popup`); hidden, it holds no subscription.
@MainActor @Suite(.serialized) struct NativePopupHostTests {
    final class Log {
        var dismissed = 0
        var laterIntercepts = 0
    }

    private static func shownPopup(_ events: InputTapTestEvents, over window: NSWindow, log: Log) throws -> NativePopupHost {
        let host = NativePopupHost(panel: NativePopupPanel(identifier: "test.popup"), input: events.tap)
        host.onDismiss = { log.dismissed += 1 }
        let anchor = CGRect(x: window.frame.midX - 20, y: window.frame.midY, width: 40, height: 20)
        try #require(host.show(size: CGSize(width: 160, height: 100), anchor: anchor, in: window, entrance: false) != nil)
        return host
    }

    @Test func aShownPopupSubscribesAndAHiddenOneHoldsNothing() throws {
        let events = InputTapTestEvents()
        let window = InputTapTestEvents.window()
        defer { window.orderOut(nil) }
        let log = Log()
        let host = try Self.shownPopup(events, over: window, log: log)
        #expect(events.tap.subscriberCount(.button, stage: .observe) == 1, "no click observer while shown")
        #expect(events.tap.subscriberCount(.key, stage: .intercept) == 1, "no Escape intercept while shown")
        host.hide()
        #expect(events.subscriptions == 0, "the hidden popup still listens")
        #expect(log.dismissed == 0, "hide() called onDismiss")
    }

    @Test func escapeInThePopupClosesItAndGoesNoFurther() throws {
        let events = InputTapTestEvents()
        let window = InputTapTestEvents.window()
        defer { window.orderOut(nil) }
        let log = Log()
        let host = try Self.shownPopup(events, over: window, log: log)
        let later = events.tap.subscribe(class: .key, phase: .intercept(order: .standard)) { _ in
            log.laterIntercepts += 1
            return .pass
        }
        #expect(!events.dispatch(try InputTapTestEvents.key(.keyDown, keyCode: 53, in: window)),
                "an Escape in the window, not the popup, was consumed")
        #expect(log.dismissed == 0)
        #expect(events.dispatch(try InputTapTestEvents.key(.keyDown, keyCode: 53, in: host.panel)),
                "the popup's Escape went on to AppKit")
        #expect(log.dismissed == 1)
        #expect(log.laterIntercepts == 1, "an intercept after the popup's heard the Escape it took")
        #expect(!host.isShown)
        #expect(events.tap.subscriberCount(.key, stage: .intercept) == 1, "only the test's own intercept is left")
        withExtendedLifetime(later) {}
    }

    @Test func aClickOutsideThePopupClosesItAndGoesOn() throws {
        let events = InputTapTestEvents()
        let window = InputTapTestEvents.window()
        defer { window.orderOut(nil) }
        let log = Log()
        let host = try Self.shownPopup(events, over: window, log: log)
        #expect(!events.dispatch(try InputTapTestEvents.mouse(.leftMouseUp, in: window)))
        #expect(log.dismissed == 0, "a button up closed the popup")
        #expect(!events.dispatch(try InputTapTestEvents.mouse(.leftMouseDown, in: host.panel)))
        #expect(log.dismissed == 0, "a click in the popup closed it")
        #expect(!events.dispatch(try InputTapTestEvents.mouse(.leftMouseDown, in: window)), "the click outside was swallowed")
        #expect(log.dismissed == 1)
        #expect(events.subscriptions == 0)
    }

    @Test func aClickThePopupKeepsOpenLeavesIt() throws {
        let events = InputTapTestEvents()
        let window = InputTapTestEvents.window()
        defer { window.orderOut(nil) }
        let log = Log()
        let host = try Self.shownPopup(events, over: window, log: log)
        host.keepsOpen = { _ in true }
        events.dispatch(try InputTapTestEvents.mouse(.rightMouseDown, in: window))
        #expect(log.dismissed == 0)
        #expect(host.isShown)
        host.hide()
    }
}
