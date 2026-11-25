import AppKit
@testable import CmuxNextActions
import Testing

/// Shortcut resolution follows AppKit's character readings, because key codes
/// identify physical positions and produce different characters on non-US layouts.
@MainActor @Suite struct ShortcutLayoutKeyTests {
    private static func event(keyCode: UInt16, character: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                      timestamp: 0, windowNumber: 0, context: nil, characters: character,
                                      charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode))
    }

    @Test func layoutCharacterWinsOverPhysicalRightBracketPosition() throws {
        let event = try Self.event(keyCode: 30, character: "=")
        let shortcut = Shortcut("=", modifiers: [.command])

        #expect(ActionRegistry.shortcuts(for: event).first == shortcut)
        #expect(shortcut.matches(event))
    }

    @Test func layoutCharacterWinsOverPhysicalLeftBracketPosition() throws {
        let event = try Self.event(keyCode: 33, character: "/")
        let shortcut = Shortcut("/", modifiers: [.command])

        #expect(ActionRegistry.shortcuts(for: event).first == shortcut)
        #expect(shortcut.matches(event))
    }
}
