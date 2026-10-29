import AppKit
@testable import CmuxNextApp
import CmuxNextInput
import Testing

/// The input journal's tap subscription, driven through a tap the way
/// `CmuxApplication.sendEvent` drives it: keys, flags, buttons, drags and scrolls are journaled,
/// pointer moves are not, and the invariant monitor hears presses and the left mouse-up.
@MainActor @Suite(.serialized)
struct InputJournalTapTests {
    /// What the monitor trigger saw: a class, so a `@MainActor` handler shares it without a local `var`.
    private final class Log {
        var count = 0
    }

    @Test func theJournalRecordsKeysButtonsDragsAndScrollsButNotMoves() throws {
        let journal = InputJournal(capacity: 64)
        journal.configure(InputJournalPolicy(enabled: true, recordsCharacters: false))
        let tap = InputEventTap()
        let log = Log()
        let subscription = InputVerificationService.subscribeJournal(journal, to: tap) { log.count += 1 }

        for event in [try Self.key(.keyDown), try Self.key(.keyUp), try Self.flags(), try Self.mouse(.leftMouseDown),
                      try Self.mouse(.mouseMoved), try Self.mouse(.leftMouseDragged), try Self.mouse(.leftMouseUp),
                      try Self.scroll()] {
            tap.dispatching {
                tap.deliverObserve(event)
                _ = tap.deliverIntercepts(event)
                tap.deliverAfterDispatch(event)
            }
        }

        let phases: [String] = journal.entries().map { entry in
            switch entry.kind {
            case .key(let key): "key.\(key.phase.rawValue)"
            case .mouse(let mouse): "mouse.\(mouse.phase.rawValue)"
            default: "other"
            }
        }
        #expect(phases == ["key.down", "key.up", "key.flags", "mouse.down", "mouse.drag", "mouse.up", "mouse.scroll"],
                "the pointer move is not journaled")
        #expect(log.count == 3, "the monitor hears the key-down, the mouse-down and the left mouse-up")
        withExtendedLifetime(subscription) {}
    }

    // MARK: helpers

    private static func key(_ type: NSEvent.EventType) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0,
                                             context: nil, characters: "a", charactersIgnoringModifiers: "a",
                                             isARepeat: false, keyCode: 0))
    }

    private static func flags() throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [.shift], timestamp: 1,
                                             windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                             isARepeat: false, keyCode: 56))
    }

    private static func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private static func scroll() throws -> NSEvent {
        _ = NSApplication.shared
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -3, wheel2: 0, wheel3: 0))
        return try #require(NSEvent(cgEvent: cgEvent))
    }
}
