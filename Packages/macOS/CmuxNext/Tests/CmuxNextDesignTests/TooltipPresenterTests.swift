import AppKit
@testable import CmuxNextDesign
import CmuxNextInput
import CmuxNextWakeupsTestSupport
import Testing

/// The tooltip presenter listens on the app's one input tap, not an AppKit event monitor
/// (p04-input-013): only while a tooltip shows or waits it observes clicks, keys and scrolls (it
/// never stops one), and a click or a key press puts the tooltip away and ends the subscription.
@MainActor @Suite(.serialized) struct TooltipPresenterTests {
    /// A presenter waiting to show `view`'s tooltip, listening on `events`' tap.
    private static func waiting(_ events: InputTapTestEvents, on view: NSView) throws -> TooltipPresenter {
        let presenter = TooltipPresenter(clock: ManualClock())
        presenter.inputTap = { events.tap }
        #expect(!presenter.isWatching)
        presenter.enter(try #require(TooltipTracker.whole(of: view)))
        try #require(presenter.isWatching, "the presenter does not watch while a tooltip waits")
        return presenter
    }

    private static func viewWithTooltip(in window: NSWindow) throws -> NSView {
        let view = NSView(frame: NSRect(x: 20, y: 20, width: 80, height: 24))
        try #require(window.contentView).addSubview(view)
        view.themedToolTip = "Reload"
        return view
    }

    @Test func aKeyPressPutsTheTooltipAwayAndEndsTheSubscription() throws {
        let events = InputTapTestEvents()
        let window = InputTapTestEvents.window()
        defer { window.orderOut(nil) }
        let presenter = try Self.waiting(events, on: try Self.viewWithTooltip(in: window))
        for eventClass in [InputEventClass.key, .button, .scroll] {
            #expect(events.tap.subscriberCount(eventClass, stage: .observe) == 1, "no \(eventClass) observer while waiting")
        }
        #expect(events.tap.subscriberCount(.key, stage: .intercept) == 0, "the tooltip intercepts what it only watches")

        events.dispatch(try InputTapTestEvents.key(.keyUp, keyCode: 0, in: window))
        #expect(presenter.isWatching, "a key up put the tooltip away")
        #expect(!events.dispatch(try InputTapTestEvents.key(.keyDown, keyCode: 0, in: window)), "the key press was swallowed")
        #expect(!presenter.isWatching, "a key press kept the tooltip")
        #expect(events.subscriptions == 0, "the observer outlived the tooltip")
    }

    @Test func aClickPutsTheTooltipAway() throws {
        let events = InputTapTestEvents()
        let window = InputTapTestEvents.window()
        defer { window.orderOut(nil) }
        let presenter = try Self.waiting(events, on: try Self.viewWithTooltip(in: window))
        #expect(!events.dispatch(try InputTapTestEvents.mouse(.leftMouseDown, in: window)))
        #expect(presenter.shown == nil)
        #expect(!presenter.isWatching)
        #expect(events.subscriptions == 0)
    }

    @Test func aScrollKeepsWatchingUntilTheScrollingStops() throws {
        let events = InputTapTestEvents()
        let window = InputTapTestEvents.window()
        defer { window.orderOut(nil) }
        let presenter = try Self.waiting(events, on: try Self.viewWithTooltip(in: window))
        events.dispatch(try InputTapTestEvents.scroll())
        // A scroll puts the tooltip away but watches on for the end of the scrolling; the new
        // subscription is added once the scroll's dispatch ends.
        #expect(presenter.isWatching)
        #expect(events.tap.subscriberCount(.scroll, stage: .observe) == 1)
        presenter.dismiss()
    }
}
