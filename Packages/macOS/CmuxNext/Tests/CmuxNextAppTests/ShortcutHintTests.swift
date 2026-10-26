import AppKit
@testable import CmuxNextApp
import CmuxNextInput
import CmuxNextWakeupsTestSupport
import Testing

/// The shortcut-hint hold watcher on the app's input tap (p04-input-016): one window-scoped observe
/// subscription per window while hints are enabled and none while they are off; it hears only its
/// window; an intentional hold shows hints and sets the tap's `hintsShowing` flag, and a key-down
/// delivered before the key router (a router-consumed key) takes them down and clears it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ShortcutHintTests {
    /// What the watcher reported: a class, so `@MainActor` closures share it without a local `var`.
    private final class Log {
        var changes: [NSEvent.ModifierFlags?] = []
        var keyDowns = 0
        var front = true
        var onChange: (() -> Void)?
    }

    private static let watchedClasses: [InputEventClass] = [.flags, .key, .button]

    @Test func enabledHintsTakeOneWindowScopedObserverAndDisabledNone() {
        let tap = InputEventTap()
        let window = Self.window()
        defer { window.orderOut(nil) }
        let monitor = WindowScopedShortcutHintModifierMonitor(window: window, tap: tap, isFront: { _ in true }) { _ in }

        #expect(Self.liveSubscriptions(tap) == 0, "a watcher with hints off subscribes to nothing")
        monitor.setEnabled(true)
        for eventClass in Self.watchedClasses {
            #expect(tap.subscriberCount(eventClass, stage: .observe) == 1, "\(eventClass) is not observed once")
        }
        #expect(Self.liveSubscriptions(tap) == Self.watchedClasses.count, "no other class or stage is subscribed")
        monitor.setEnabled(false)
        #expect(Self.liveSubscriptions(tap) == 0, "turning hints off drops the subscription")
    }

    @Test func onlyTheWatchersWindowIsHeardAndOnlyWhileItIsInFront() throws {
        let tap = InputEventTap()
        let mine = Self.window(), other = Self.window()
        defer { for window in [mine, other] { window.orderOut(nil) } }
        let log = Log()
        let monitor = WindowScopedShortcutHintModifierMonitor(window: mine, tap: tap, isFront: { _ in log.front },
                                                              keepsHints: { _ in log.keyDowns += 1; return false }) { _ in }
        monitor.setEnabled(true)
        defer { monitor.stop() }

        try Self.dispatch(Self.key(in: other), through: tap)
        #expect(log.keyDowns == 0, "another window's key-down reached this window's watcher")
        try Self.dispatch(Self.key(in: mine), through: tap)
        #expect(log.keyDowns == 1, "this window's key-down was not heard")
        try Self.dispatch(Self.key(type: .keyUp, in: mine), through: tap)
        #expect(log.keyDowns == 1, "a key-up is not a key-down")
        log.front = false
        try Self.dispatch(Self.key(in: mine), through: tap)
        #expect(log.keyDowns == 1, "a window that is not in front does no hint work")
    }

    @Test func anIntentionalHoldShowsHintsAndSetsTheTapFlagUntilAKeyDown() async throws {
        let tap = InputEventTap()
        let clock = ManualClock()
        let window = Self.window()
        defer { window.orderOut(nil) }
        let log = Log()
        let monitor = WindowScopedShortcutHintModifierMonitor(window: window, tap: tap, clock: clock, isFront: { _ in true }) { flags in
            log.changes.append(flags)
            log.onChange?()
        }
        monitor.setEnabled(true)
        defer { monitor.stop() }

        try Self.dispatch(Self.flags([.command], in: window), through: tap)
        #expect(log.changes.isEmpty, "hints show only after the intentional-hold delay")
        try await clock.waitForSleeper()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            log.onChange = {
                log.onChange = nil
                continuation.resume()
            }
            clock.advance(by: ShortcutHintModifierPolicy.intentionalHoldDelay)
        }
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

    // MARK: helpers

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

    private static func flags(_ flags: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 1,
                                      windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                      isARepeat: false, keyCode: 55))
    }
}
