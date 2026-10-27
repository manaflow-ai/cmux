import AppKit
import CoreGraphics
@testable import CmuxNextBrowser
import Testing

/// Task 229 of plans/cmux-next/chrome-parity/p01-process.md: a hosted page's pointer lock, keyboard
/// lock and HTML fullscreen, as Chrome's ExclusiveAccessManager keeps them. Only a page that has the
/// keyboard takes a lock; the pointer lock hides and holds cmux's cursor and sends raw movement;
/// Escape ends every lock and the fullscreen (a held Escape when the lock takes Escape); losing the
/// keyboard, showing another page and the host's end free the cursor.
@MainActor
@Suite struct ChromiumHostExclusiveAccessTests {
    /// Records each call to the page's browser.
    @MainActor final class Recorder: ChromiumHostExclusiveAccessWire {
        var calls: [String] = []
        func exitPointerLock(_ browser: Int32, byUser: Bool) { calls.append("exit pointer \(browser) \(byUser)") }
        func exitKeyboardLock(_ browser: Int32) { calls.append("exit keyboard \(browser)") }
        func exitFullscreen(_ browser: Int32) { calls.append("exit fullscreen \(browser)") }
        func sendLockedMove(_ browser: Int32, dx: Double, dy: Double, modifiers: Int32) {
            calls.append("move \(browser) \(dx),\(dy) \(modifiers)")
        }
    }

    /// The cursor's lock and unlock, in order.
    @MainActor final class Cursor {
        var calls: [String] = []
        var lock: ChromiumHostCursorLock {
            ChromiumHostCursorLock(lock: { [self] in calls.append("lock") }, unlock: { [self] in calls.append("unlock") })
        }
    }

    static func access(_ wire: Recorder?, cursor: Cursor) -> ChromiumHostExclusiveAccess {
        let access = ChromiumHostExclusiveAccess(cursor: cursor.lock)
        access.wire = wire
        return access
    }

    /// A mouse move with `delta` and the unaccelerated movement `raw` (the event's fields 170 and 171).
    static func move(delta: CGPoint, raw: CGPoint) throws -> NSEvent {
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 50, y: 50),
                                         mouseButton: .left))
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y))
        event.setDoubleValueField(try #require(CGEventField(rawValue: 170)), value: raw.x)
        event.setDoubleValueField(try #require(CGEventField(rawValue: 171)), value: raw.y)
        return try #require(NSEvent(cgEvent: event))
    }

    @Test func aPointerLockNeedsTheKeyboardAndHoldsTheCursor() throws {
        let wire = Recorder()
        let cursor = Cursor()
        let access = Self.access(wire, cursor: cursor)
        #expect(!access.handle(.pointerLockRequested, browser: 7, detail: 0, mayLock: false), "a page without the keyboard locks nothing")
        #expect(cursor.calls.isEmpty)
        #expect(access.handle(.pointerLockRequested, browser: 7, detail: 0, mayLock: true))
        #expect(access.handle(.pointerLockRequested, browser: 7, detail: 0, mayLock: true), "a second request keeps the lock")
        #expect(cursor.calls == ["lock"], "the cursor is hidden and held once")

        #expect(access.lockedMove(try Self.move(delta: CGPoint(x: 3, y: -2), raw: CGPoint(x: 9, y: 9))))
        #expect(wire.calls.last?.hasPrefix("move 7 3.0,-2.0 ") == true, "the event's deltas, as the page view sees them")

        #expect(!access.handle(.pointerUnlocked, browser: 8, detail: 0, mayLock: false), "another page's unlock changes nothing")
        #expect(access.handle(.pointerUnlocked, browser: 7, detail: 0, mayLock: false))
        #expect(cursor.calls == ["lock", "unlock"])
        #expect(!access.lockedMove(try Self.move(delta: CGPoint(x: 1, y: 1), raw: .zero)), "unlocked, a move is a pointer move")
    }

    /// `requestPointerLock({unadjustedMovement: true})`: the mouse's own deltas, as WebMouseEventBuilder reads them.
    @Test func unadjustedMovementSendsTheUnacceleratedDeltas() throws {
        let wire = Recorder()
        let access = Self.access(wire, cursor: Cursor())
        access.handle(.pointerLockRequested, browser: 7, detail: 1, mayLock: true)
        #expect(access.pointerLock?.unadjustedMovement == true)
        #expect(access.lockedMove(try Self.move(delta: CGPoint(x: 3, y: -2), raw: CGPoint(x: 5, y: 4))))
        #expect(wire.calls.last?.hasPrefix("move 7 5.0,4.0 ") == true)
    }

    @Test func escapeEndsEveryLockAndTheFullscreen() {
        let wire = Recorder()
        let cursor = Cursor()
        let access = Self.access(wire, cursor: cursor)
        access.fullscreenChanged(true, browser: 7)
        access.handle(.pointerLockRequested, browser: 7, detail: 0, mayLock: true)
        access.handle(.keyboardLockRequested, browser: 7, detail: 0, mayLock: true)
        #expect(access.holdsKeys)
        #expect(access.escape(down: true, isRepeat: false, at: 10), "the page never gets that Escape")
        #expect(wire.calls == ["exit pointer 7 true", "exit keyboard 7", "exit fullscreen 7"])
        #expect(cursor.calls == ["lock", "unlock"])
        #expect(access.pointerLock == nil && access.keyboardLock == nil && !access.holdsKeys)
        access.fullscreenChanged(false, browser: 7)
        #expect(!access.isActive)
        #expect(!access.escape(down: true, isRepeat: false, at: 11), "with nothing held Escape is the page's")
    }

    @Test func escapeEndsAFullscreenAlone() {
        let wire = Recorder()
        let access = Self.access(wire, cursor: Cursor())
        access.fullscreenChanged(true, browser: 7)
        #expect(access.escape(down: true, isRepeat: false, at: 1))
        #expect(wire.calls == ["exit fullscreen 7"])
    }

    /// A keyboard lock that takes Escape: the page gets Escape, and only Escape held 1.5 s ends the locks.
    @Test func aLockThatTakesEscapeEndsOnAHeldEscape() {
        let wire = Recorder()
        let access = Self.access(wire, cursor: Cursor())
        access.fullscreenChanged(true, browser: 7)
        access.handle(.keyboardLockRequested, browser: 7, detail: 1, mayLock: true)
        #expect(!access.escape(down: true, isRepeat: false, at: 10), "a press is the page's")
        #expect(!access.escape(down: true, isRepeat: true, at: 11), "held 1 s is still the page's")
        #expect(!access.escape(down: false, isRepeat: false, at: 11.2))
        #expect(!access.escape(down: true, isRepeat: false, at: 20))
        #expect(!access.escape(down: true, isRepeat: true, at: 21))
        #expect(access.escape(down: true, isRepeat: true, at: 21.6), "held 1.5 s ends them")
        #expect(wire.calls == ["exit keyboard 7", "exit fullscreen 7"])
    }

    /// A keyboard lock takes cmux's keys only in its page's fullscreen, as Chrome activates it.
    @Test func aKeyboardLockHoldsKeysOnlyInFullscreen() {
        let access = Self.access(Recorder(), cursor: Cursor())
        #expect(access.handle(.keyboardLockRequested, browser: 7, detail: 0, mayLock: true))
        #expect(!access.holdsKeys)
        access.fullscreenChanged(true, browser: 8)
        #expect(!access.holdsKeys, "another page's fullscreen")
        access.fullscreenChanged(true, browser: 7)
        #expect(access.holdsKeys)
        access.handle(.keyboardUnlocked, browser: 7, detail: 0, mayLock: false)
        #expect(!access.holdsKeys)
    }

    @Test func losingTheKeyboardEndsThePointerLock() {
        let wire = Recorder()
        let cursor = Cursor()
        let access = Self.access(wire, cursor: cursor)
        access.handle(.pointerLockRequested, browser: 7, detail: 0, mayLock: true)
        access.focusLost()
        #expect(wire.calls == ["exit pointer 7 false"], "not by the person: no cooldown")
        #expect(cursor.calls == ["lock", "unlock"])
    }

    @Test func showingAnotherPageEndsWhatTheOldOneHeld() {
        let wire = Recorder()
        let cursor = Cursor()
        let access = Self.access(wire, cursor: cursor)
        access.fullscreenChanged(true, browser: 7)
        access.handle(.pointerLockRequested, browser: 7, detail: 0, mayLock: true)
        access.handle(.keyboardLockRequested, browser: 7, detail: 0, mayLock: true)
        access.showing(7)
        #expect(wire.calls.isEmpty, "the same page keeps them")
        access.showing(9)
        #expect(wire.calls == ["exit pointer 7 false", "exit keyboard 7", "exit fullscreen 7"])
        #expect(cursor.calls == ["lock", "unlock"])
        #expect(!access.isActive)
    }

    @Test func theHostsEndFreesTheCursorAndSendsNothing() {
        let wire = Recorder()
        let cursor = Cursor()
        let access = Self.access(wire, cursor: cursor)
        access.fullscreenChanged(true, browser: 7)
        access.handle(.pointerLockRequested, browser: 7, detail: 0, mayLock: true)
        access.hostEnded()
        #expect(wire.calls.isEmpty)
        #expect(cursor.calls == ["lock", "unlock"])
        #expect(!access.isActive)
    }

    /// Feature `chromiumHostLocks` off: no wire, so nothing is granted and Escape stays the page's.
    @Test func withNoWireNothingIsTaken() {
        let cursor = Cursor()
        let access = Self.access(nil, cursor: cursor)
        #expect(!access.handle(.pointerLockRequested, browser: 7, detail: 0, mayLock: true))
        #expect(!access.handle(.keyboardLockRequested, browser: 7, detail: 0, mayLock: true))
        access.fullscreenChanged(true, browser: 7)
        #expect(!access.escape(down: true, isRepeat: false, at: 1))
        #expect(cursor.calls.isEmpty)
    }

    /// The page view: Escape reaches the exclusive access before the page's key frames, and a locked
    /// move never reaches the page as a pointer move.
    @Test func thePageViewGivesEscapeAndLockedMovesToTheExclusiveAccess() throws {
        let page = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), inputTarget: .view)
        let wire = Recorder()
        page.exclusiveAccess.wire = wire
        page.exclusiveAccess.fullscreenChanged(true, browser: 7)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0,
                                                   context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                   isARepeat: false, keyCode: 53))
        #expect(page.exclusiveAccess.takesEscape(escape, phase: 0))
        #expect(wire.calls == ["exit fullscreen 7"])
        let shiftEscape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 2, windowNumber: 0,
                                                        context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                        isARepeat: false, keyCode: 53))
        #expect(!page.exclusiveAccess.takesEscape(shiftEscape, phase: 0), "a chord with Escape is the page's")
        #expect(!page.exclusiveAccess.takesMove(try Self.move(delta: CGPoint(x: 1, y: 1), raw: .zero), phase: 0))
        #expect(!ChromiumHostExclusiveAccess.mayLock(page), "a page view in no window has no keyboard")
    }

    @Test func lockEventsDecode() {
        #expect(ChromiumHostLockEvent(rawValue: 0) == .pointerLockRequested)
        #expect(ChromiumHostLockEvent(rawValue: 1) == .pointerUnlocked)
        #expect(ChromiumHostLockEvent(rawValue: 2) == .keyboardLockRequested)
        #expect(ChromiumHostLockEvent(rawValue: 3) == .keyboardUnlocked)
        #expect(ChromiumHostLockEvent(rawValue: 4) == nil)
    }
}
