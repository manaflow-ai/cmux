import AppKit
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Testing

/// A Command or Control chord that `performKeyEquivalent` passed on comes back to `keyDown`, whose
/// `interpretKeyEvents` may end in `doCommand`: that re-sends the key down being interpreted, stored at
/// `keyDown` (DC7), never AppKit's current event, which after the key's dispatch is
/// whatever came last.
@MainActor @Suite(.serialized)
struct TerminalKeyTests {
    /// The keys `doCommand` re-sent, in order.
    @MainActor final class Resent { var keys: [NSEvent] = [] }

    /// A live terminal, first responder of a borderless window, whose re-sends are recorded.
    struct Harness {
        let session: TerminalSession
        let io: ScriptedTerminalIO
        let window: NSWindow
        let resent: Resent

        var view: TerminalSurfaceView { session.surfaceView }

        func close() {
            io.finish()
            window.contentView = nil
            window.close()
            session.close()
        }
    }

    static func harness() throws -> Harness {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.view
        session.view.frame = NSRect(x: 0, y: 0, width: 480, height: 240)
        session.view.layoutSubtreeIfNeeded()
        window.makeFirstResponder(session.surfaceView)
        let resent = Resent()
        session.surfaceView.resendKey = { resent.keys.append($0) }
        return Harness(session: session, io: io, window: window, resent: resent)
    }

    /// Return (`insertNewline:` through the input methods) at `timestamp`.
    static func returnKey(at timestamp: TimeInterval, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp,
                                      windowNumber: window.windowNumber, context: nil, characters: "\r",
                                      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    @Test func doCommandResendsTheKeyDownItInterprets() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let key = try Self.returnKey(at: 7, in: harness.window)
        harness.view.lastPerformKeyEventTimestamp = key.timestamp
        harness.view.interpret(key, as: key)
        #expect(harness.resent.keys.count == 1, "the passed-on chord was not sent again")
        #expect(harness.resent.keys.first === key, "another event than the key down was sent again")
        #expect(harness.view.interpretingKeyDown == nil, "the key down outlived its interpretation")
    }

    @Test func doCommandOutsideAKeyDownSendsNothing() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let key = try Self.returnKey(at: 8, in: harness.window)
        // A socket or menu run after the key: AppKit's current event may still be that key.
        harness.view.lastPerformKeyEventTimestamp = key.timestamp
        harness.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(harness.resent.keys.isEmpty, "a command outside keyDown re-sent an old key")
    }

    @Test func doCommandForAnotherKeySendsNothing() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let key = try Self.returnKey(at: 9, in: harness.window)
        harness.view.lastPerformKeyEventTimestamp = 3 // an earlier chord's pass
        harness.view.interpret(key, as: key)
        #expect(harness.resent.keys.isEmpty, "a key no chord passed on was sent again")
    }
}
