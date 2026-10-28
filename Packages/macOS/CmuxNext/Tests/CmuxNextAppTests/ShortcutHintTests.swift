import AppKit
@testable import CmuxNextApp
import CmuxNextInput
import CmuxNextWakeups
import Testing

/// The shortcut-hint hold watcher on the app's input tap: observe subscriptions while
/// hints are enabled and none while they are off. It hears its own window's modifier changes and, only
/// while a modifier is held there, its key-downs and any window's mouse-downs, so a plain key does no
/// hint work. An intentional hold shows hints and sets the tap's `hintsShowing` flag; a key-down
/// delivered before the key router (a router-consumed key), a click, resigning key or turning hints
/// off takes them down and clears it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ShortcutHintTests {
    /// What the watcher did: a class, so the watcher's closures share it without a local `var`.
    private final class Log {
        var changes: [NSEvent.ModifierFlags?] = []
        var keepsHintsCalls = 0
        var frontCalls = 0
        var front = true
        var keeps = false
        var onChange: (() -> Void)?
    }

    private static let watchedClasses: [InputEventClass] = [.flags, .key, .button]

    @Test func enabledHintsObserveTheirClassesAndDisabledNone() {
        let tap = InputEventTap()
        let window = Self.window()
        defer { window.orderOut(nil) }
        let monitor = Self.monitor(window, tap: tap, log: Log())

        #expect(Self.liveSubscriptions(tap) == 0, "a watcher with hints off subscribes to nothing")
        monitor.setEnabled(true)
        for eventClass in Self.watchedClasses {
            #expect(tap.subscriberCount(eventClass, stage: .observe) == 1, "\(eventClass) is not observed once")
        }
        #expect(Self.liveSubscriptions(tap) == Self.watchedClasses.count, "no other class or stage is subscribed")
        monitor.setEnabled(false)
        #expect(Self.liveSubscriptions(tap) == 0, "turning hints off drops the subscriptions")
    }

    @Test func aKeyOrClickWithNoModifierHeldDoesNoHintWork() throws {
        let tap = InputEventTap()
        let window = Self.window()
        defer { window.orderOut(nil) }
        let log = Log()
        let monitor = Self.monitor(window, tap: tap, log: log)
        monitor.setEnabled(true)
        defer { monitor.stop() }

        try Self.dispatch(Self.key(in: window), through: tap)
        try Self.dispatch(Self.click(in: window), through: tap)
        #expect(log.keepsHintsCalls == 0, "a plain key resolved the hint keys")
        #expect(log.frontCalls == 0, "a plain key or click asked which window is in front")

        try Self.dispatch(Self.flags([.command], in: window), through: tap)
        try Self.dispatch(Self.flags([], in: window), through: tap)
        let front = log.frontCalls
        try Self.dispatch(Self.key(in: window), through: tap)
        try Self.dispatch(Self.click(in: window), through: tap)
        #expect(log.keepsHintsCalls == 0, "a key after the release resolved the hint keys")
        #expect(log.frontCalls == front, "a key or click after the release asked which window is in front")
    }

    @Test func onlyTheWatchersWindowsKeysAreHeardAndOnlyWhileItIsInFront() throws {
        let tap = InputEventTap()
        let mine = Self.window(), other = Self.window()
        defer { for window in [mine, other] { window.orderOut(nil) } }
        let log = Log()
        let monitor = Self.monitor(mine, tap: tap, log: log)
        monitor.setEnabled(true)
        defer { monitor.stop() }

        try Self.dispatch(Self.flags([.command], in: other), through: tap)
        try Self.dispatch(Self.key(in: mine), through: tap)
        #expect(log.keepsHintsCalls == 0, "another window's modifier change started a hold here")

        try Self.dispatch(Self.flags([.command], in: mine), through: tap)
        try Self.dispatch(Self.key(in: other), through: tap)
        #expect(log.keepsHintsCalls == 0, "another window's key-down reached this window's watcher")
        try Self.dispatch(Self.key(in: mine), through: tap)
        #expect(log.keepsHintsCalls == 1, "this window's key-down was not heard")
        try Self.dispatch(Self.key(type: .keyUp, in: mine), through: tap)
        #expect(log.keepsHintsCalls == 1, "a key-up is not a key-down")
        log.front = false
        try Self.dispatch(Self.key(in: mine), through: tap)
        #expect(log.keepsHintsCalls == 1, "a window that is not in front does no hint work")
    }

    @Test func anIntentionalHoldShowsHintsAndSetsTheTapFlagUntilAKeyDown() async throws {
        let tap = InputEventTap()
        let rig = MainDeadlineRig()
        let window = Self.window()
        defer { window.orderOut(nil) }
        let log = Log()
        let monitor = Self.monitor(window, tap: tap, rig: rig, log: log)
        monitor.setEnabled(true)
        defer { monitor.stop() }

        try Self.dispatch(Self.flags([.command], in: window), through: tap)
        #expect(log.changes.isEmpty, "hints show only after the intentional-hold delay")
        try Self.finishHold(rig: rig)
        #expect(log.changes == [.command])
        #expect(monitor.showing)
        #expect(tap.flags.contains(.hintsShowing), "showing hints did not set the tap's hints flag")

        // Delivered at the observe stage, before the key router, as a router-consumed key is.
        try Self.dispatch(Self.key(in: window), through: tap)
        #expect(log.changes == [.command, nil], "a key-down did not take the hints down")
        #expect(!monitor.showing)
        #expect(!tap.flags.contains(.hintsShowing), "hiding hints did not clear the tap's hints flag")

        try Self.dispatch(Self.key(in: window), through: tap)
        #expect(log.changes == [.command, nil], "a key-down with no hint up reports nothing")
    }

    /// The hold deadline is a wake of the main thread's one queue with WakeLeeway's slack (8 ms at 300 ms), so it
    /// shares a wake with other deadlines, and its fire shows the hints.
    @Test func theHoldDeadlineIsAMainDeadlineInWakeLeewaysWindow() async throws {
        let tap = InputEventTap()
        let rig = MainDeadlineRig()
        let window = Self.window()
        defer { window.orderOut(nil) }
        let log = Log()
        let monitor = Self.monitor(window, tap: tap, rig: rig, log: log)
        monitor.setEnabled(true)
        defer { monitor.stop() }

        try Self.dispatch(Self.flags([.command], in: window), through: tap)
        let hold = ShortcutHintModifierPolicy.intentionalHoldDelay
        let wake = try #require(rig.deadlines.nextFire, "the hold armed no deadline")
        #expect(wake >= hold && wake <= hold + WakeLeeway.defaultAlignment, "the hold wakes in WakeLeeway's 8 ms window")
        try Self.finishHold(rig: rig)
        #expect(log.changes == [.command], "the hold's deadline did not show the hints")
    }

    @Test func aPaneNavigationKeyKeepsTheHintsAndTheFlag() async throws {
        let tap = InputEventTap()
        let rig = MainDeadlineRig()
        let window = Self.window()
        defer { window.orderOut(nil) }
        let log = Log()
        log.keeps = true
        let monitor = Self.monitor(window, tap: tap, rig: rig, log: log)
        monitor.setEnabled(true)
        defer { monitor.stop() }

        try Self.showHints(in: window, tap: tap, rig: rig, log: log)
        try Self.dispatch(Self.key(in: window), through: tap)
        #expect(log.keepsHintsCalls == 1)
        #expect(log.changes == [.command], "a key that keeps hints took them down")
        #expect(monitor.showing)
        #expect(tap.flags.contains(.hintsShowing), "a key that keeps hints cleared the tap's hints flag")
    }

    @Test func aClickInThisWindowHidesTheHints() async throws {
        let tap = InputEventTap()
        let rig = MainDeadlineRig()
        let window = Self.window()
        defer { window.orderOut(nil) }
        let log = Log()
        let monitor = Self.monitor(window, tap: tap, rig: rig, log: log)
        monitor.setEnabled(true)
        defer { monitor.stop() }

        try Self.showHints(in: window, tap: tap, rig: rig, log: log)
        try Self.dispatch(Self.click(in: window, modifiers: [.command]), through: tap)
        #expect(log.changes == [.command, nil], "a click did not take the hints down")
        #expect(!tap.flags.contains(.hintsShowing))
    }

    @Test func aCommandClickInAnotherWindowHidesTheHints() async throws {
        let tap = InputEventTap()
        let rig = MainDeadlineRig()
        let mine = Self.window(), other = Self.window()
        defer { for window in [mine, other] { window.orderOut(nil) } }
        let log = Log()
        let monitor = Self.monitor(mine, tap: tap, rig: rig, log: log)
        monitor.setEnabled(true)
        defer { monitor.stop() }

        try Self.showHints(in: mine, tap: tap, rig: rig, log: log)
        // A Cmd-click on a background window does not make it key: this window stays in front.
        try Self.dispatch(Self.click(in: other, modifiers: [.command]), through: tap)
        #expect(log.changes == [.command, nil], "a click in another window left the hints up")
        #expect(!monitor.showing)
        #expect(!tap.flags.contains(.hintsShowing))
    }

    @Test func resigningKeyHidesTheHintsAndForgetsTheHold() async throws {
        let tap = InputEventTap()
        let rig = MainDeadlineRig()
        let window = Self.window()
        defer { window.orderOut(nil) }
        let log = Log()
        let notifications = NotificationCenter()
        let monitor = Self.monitor(window, tap: tap, notifications: notifications, rig: rig, log: log)
        monitor.setEnabled(true)
        defer { monitor.stop() }

        try Self.showHints(in: window, tap: tap, rig: rig, log: log)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            log.onChange = {
                log.onChange = nil
                continuation.resume()
            }
            notifications.post(name: NSWindow.didResignKeyNotification, object: window)
        }
        #expect(log.changes == [.command, nil], "resigning key left the hints up")
        #expect(!monitor.showing)
        #expect(!tap.flags.contains(.hintsShowing), "resigning key left the tap's hints flag set")

        // The hold's release goes to another window now: this window no longer counts it as held.
        try Self.dispatch(Self.key(in: window), through: tap)
        #expect(log.keepsHintsCalls == 0, "a key after resigning key still did hint work")
    }

    /// The app's resign-active notice reaches the watcher through the app's one observer (AppEvents) and hides the
    /// hints in the notice's own turn; another window's resign-key leaves them up.
    @Test func resigningActiveHidesTheHintsInItsTurnAndAnotherWindowsResignKeyDoesNot() throws {
        let tap = InputEventTap()
        let rig = MainDeadlineRig()
        let window = Self.window()
        let other = Self.window()
        defer { window.orderOut(nil); other.orderOut(nil) }
        let log = Log()
        let notifications = NotificationCenter()
        let monitor = Self.monitor(window, tap: tap, notifications: notifications, rig: rig, log: log)
        monitor.setEnabled(true)
        defer { monitor.stop() }

        try Self.showHints(in: window, tap: tap, rig: rig, log: log)
        notifications.post(name: NSWindow.didResignKeyNotification, object: other)
        #expect(log.changes == [.command], "another window resigning key hid this window's hints")
        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(log.changes == [.command, nil], "resigning active left the hints up past its turn")
        #expect(!tap.flags.contains(.hintsShowing))
    }

    @Test func turningHintsOffWhileTheyShowClearsTheFlag() async throws {
        let tap = InputEventTap()
        let rig = MainDeadlineRig()
        let window = Self.window()
        defer { window.orderOut(nil) }
        let log = Log()
        let monitor = Self.monitor(window, tap: tap, rig: rig, log: log)
        monitor.setEnabled(true)

        try Self.showHints(in: window, tap: tap, rig: rig, log: log)
        monitor.setEnabled(false)
        #expect(log.changes == [.command, nil], "turning hints off left them up")
        #expect(!monitor.showing)
        #expect(!tap.flags.contains(.hintsShowing), "turning hints off left the tap's hints flag set")
        #expect(Self.liveSubscriptions(tap) == 0)
    }

    // MARK: helpers

    private static func monitor(_ window: NSWindow, tap: InputEventTap, notifications: NotificationCenter = NotificationCenter(),
                                rig: MainDeadlineRig = MainDeadlineRig(), log: Log) -> WindowScopedShortcutHintModifierMonitor {
        WindowScopedShortcutHintModifierMonitor(window: window, tap: tap, deadlines: rig.deadlines, events: AppEvents(center: notifications),
                                                windowEvents: WindowEvents(window: window, center: notifications),
                                                isFront: { _ in log.frontCalls += 1; return log.front },
                                                keepsHints: { _ in log.keepsHintsCalls += 1; return log.keeps }) { flags in
            log.changes.append(flags)
            log.onChange?()
        }
    }

    /// Holds Command in `window` past the intentional-hold delay; the hints show.
    private static func showHints(in window: NSWindow, tap: InputEventTap, rig: MainDeadlineRig, log: Log) throws {
        try Self.dispatch(Self.flags([.command], in: window), through: tap)
        try finishHold(rig: rig)
        #expect(log.changes == [.command], "the hold did not show hints")
        #expect(tap.flags.contains(.hintsShowing))
    }

    /// Fires the pending hold deadline and runs its action in one frame.
    private static func finishHold(rig: MainDeadlineRig) throws {
        try #require(rig.deadlines.nextFire != nil, "no hold deadline is pending")
        rig.fireAndRun()
    }

    private static func liveSubscriptions(_ tap: InputEventTap) -> Int {
        InputEventClass.allCases.reduce(0) { total, eventClass in
            total + [InputEventTap.Stage.observe, .intercept, .afterDispatch].reduce(0) { $0 + tap.subscriberCount(eventClass, stage: $1) }
        }
    }

    /// Drives one event through the tap the way `CmuxApplication.sendEvent` does.
    private static func dispatch(_ event: NSEvent, through tap: InputEventTap) {
        tap.dispatching {
            tap.deliverObserve(event)
            _ = tap.deliverIntercepts(event)
            tap.deliverAfterDispatch(event)
        }
    }

    private static func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    private static func key(type: NSEvent.EventType = .keyDown, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
                                      context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    }

    private static func click(in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: modifiers, timestamp: 1,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private static func flags(_ flags: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 1,
                                      windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                      isARepeat: false, keyCode: 55))
    }
}
