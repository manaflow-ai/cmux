import AppKit
@testable import CmuxNextDesign
import CmuxNextInput
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The tooltip presenter listens on the app's one input tap, not an AppKit event monitor:
/// only while a tooltip shows or waits it observes clicks, keys and scrolls (it
/// never stops one), and a click or a key press puts the tooltip away and ends the subscription.
@MainActor @Suite(.serialized) struct TooltipPresenterTests {
    /// A presenter waiting to show `view`'s tooltip, listening on `events`' tap.
    private static func waiting(_ events: InputTapTestEvents, on view: NSView, clock: ManualClock = ManualClock(),
                                notifications: NotificationCenter = NotificationCenter()) throws -> TooltipPresenter {
        let presenter = TooltipPresenter(clock: clock)
        presenter.inputTap = events.tap
        presenter.appEvents = AppEvents(center: notifications)
        presenter.timing = .standard // a delay, whatever the tunables say
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

    /// The tap carries no AppKit-defined event, so the app going inactive comes as a notification: a
    /// tooltip still waiting on its delay is put away (its timer must not show it over the other app),
    /// and the warm group ends with it.
    @Test func theAppGoingInactivePutsAWaitingTooltipAway() async throws {
        let events = InputTapTestEvents()
        let window = InputTapTestEvents.window()
        defer { window.orderOut(nil) }
        let clock = ManualClock()
        let notifications = NotificationCenter()
        let presenter = try Self.waiting(events, on: try Self.viewWithTooltip(in: window), clock: clock,
                                         notifications: notifications)
        try await clock.waitForSleeper() // the tooltip's delay is pending
        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(!presenter.isWatching, "the inactive app kept the waiting tooltip")
        #expect(presenter.shown == nil)
        #expect(events.subscriptions == 0, "the observer outlived the tooltip")
        clock.advance(by: .seconds(2)) // past the delay: its timer was cancelled
        await Task.yield()
        #expect(presenter.shown == nil, "the delay's timer showed the tooltip over the other app")
    }

    /// A tooltip that comes while the pointer is already over its view (a web page's `title=`, which the
    /// page sends once the pointer reaches the element) enters at once, as Chrome's
    /// `-setToolTipAtMousePoint:` fakes AppKit's enter: a tracking area added under a still pointer
    /// reports no enter, so it would never show. It hangs below the pointer, not the view; with the
    /// pointer elsewhere it waits for a real enter.
    @Test func aTooltipSetAtThePointerEntersAtOnceAndHangsBelowIt() throws {
        let events = InputTapTestEvents()
        let window = InputTapTestEvents.window()
        defer {
            window.orderOut(nil)
            PointerHover.debugPointers[ObjectIdentifier(window)] = nil
        }
        let view = NSView(frame: NSRect(x: 20, y: 20, width: 200, height: 100))
        try #require(window.contentView).addSubview(view)
        let presenter = TooltipPresenter(clock: ManualClock())
        presenter.inputTap = events.tap
        presenter.appEvents = AppEvents(center: NotificationCenter())
        presenter.timing = .standard

        PointerHover.setDebugPointer(NSPoint(x: 300, y: 250), in: window)
        TooltipTracker.setAtPointer("Elsewhere", on: view, presenter: presenter)
        #expect(!presenter.isWatching, "a tooltip entered with the pointer outside its view")
        TooltipTracker.setAtPointer(nil, on: view, presenter: presenter)
        #expect(view.themedToolTip == nil)

        PointerHover.setDebugPointer(NSPoint(x: 70, y: 50), in: window)
        TooltipTracker.setAtPointer("Open the menu", on: view, presenter: presenter)
        #expect(view.themedToolTip == "Open the menu")
        #expect(presenter.isWatching, "the tooltip under a still pointer never entered")
        let anchor = try #require(TooltipTracker.whole(of: view)?.anchorScreenRect)
        let pointer = window.convertPoint(toScreen: NSPoint(x: 70, y: 50))
        #expect(anchor.minX == pointer.x && anchor.maxY == pointer.y, "it hangs below the view, not the pointer")
        #expect(anchor.height == TooltipTracker.pointerDrop)
        presenter.dismiss()
        #expect(!presenter.isWatching)
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
