import AppKit
@testable import CmuxNextActions
import Testing

/// Bracket shortcuts are delivered with the shifted character on some AppKit
/// paths. Their physical key code still identifies the catalog key.
@MainActor @Suite struct ShortcutPhysicalKeyTests {
    private static func event(keyCode: UInt16, characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                      timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    @Test func shiftedLeftBracketKeepsItsBaseKey() throws {
        let event = try Self.event(keyCode: 33, characters: "{")
        let shortcut = Shortcut("[", modifiers: [.command, .shift])

        #expect(Shortcut.eventKey(event) == "[")
        #expect(ActionRegistry.shortcuts(for: event).first == shortcut)
        #expect(shortcut.matches(event))
        #expect(ShortcutRecorder.shortcut(for: event) == shortcut)
    }

    @Test func shiftedRightBracketKeepsItsBaseKey() throws {
        let event = try Self.event(keyCode: 30, characters: "}")
        let shortcut = Shortcut("]", modifiers: [.command, .shift])

        #expect(Shortcut.eventKey(event) == "]")
        #expect(ActionRegistry.shortcuts(for: event).first == shortcut)
        #expect(shortcut.matches(event))
        #expect(ShortcutRecorder.shortcut(for: event) == shortcut)
    }
}
