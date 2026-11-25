import AppKit
@testable import CmuxNextActions
import Testing

/// `app.shortcutLayout` Keep QWERTY Positions: on Dvorak the key at QWERTY C types j,
/// yet Cmd at that key is Cmd-C, as macOS's "Dvorak - QWERTY Command" layout.
@MainActor @Suite struct ShortcutQwertyPositionsTests {
    /// The key at QWERTY C (kVK_ANSI_C, 8) on Dvorak types "j".
    private static func dvorakC(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                      timestamp: 0, windowNumber: 0, context: nil, characters: "j",
                                      charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 8))
    }

    @Test func typedLetterByDefault() throws {
        let event = try Self.dvorakC([.command])
        #expect(ActionRegistry.shortcuts(for: event, qwerty: false).first == Shortcut("j", modifiers: [.command]))
        #expect(Shortcut("j", modifiers: [.command]).matches(event, qwerty: false))
        #expect(!Shortcut("c", modifiers: [.command]).matches(event, qwerty: false))
    }

    @Test func qwertyPositionWithCommand() throws {
        let event = try Self.dvorakC([.command])
        #expect(ActionRegistry.shortcuts(for: event, qwerty: true) == [Shortcut("c", modifiers: [.command])])
        #expect(Shortcut("c", modifiers: [.command]).matches(event, qwerty: true))
        #expect(!Shortcut("j", modifiers: [.command]).matches(event, qwerty: true))
    }

    @Test func qwertyPositionWithControlAndShift() throws {
        let event = try Self.dvorakC([.control, .shift])
        #expect(ActionRegistry.shortcuts(for: event, qwerty: true) == [Shortcut("c", modifiers: [.control, .shift])])
    }

    @Test func plainKeysStayTyped() throws {
        let event = try Self.dvorakC([])
        #expect(ActionRegistry.shortcuts(for: event, qwerty: true).first == Shortcut("j", modifiers: []))
    }

    @Test func registryReadsItsOwnSwitch() throws {
        let event = try Self.dvorakC([.command])
        let registry = ActionRegistry()
        #expect(registry.shortcuts(for: event).first == Shortcut("j", modifiers: [.command]))
        registry.matchesQwertyPositions = true
        #expect(registry.shortcuts(for: event) == [Shortcut("c", modifiers: [.command])])
        #expect(ActionRegistry().shortcuts(for: event).first == Shortcut("j", modifiers: [.command]))
    }

    @Test func recorderRecordsTheQwertyKey() throws {
        let event = try Self.dvorakC([.command])
        // The typed reading (no qwerty) re-translates the key code through the runner's layout, so it is not asserted.
        #expect(ShortcutRecorder.shortcut(for: event, qwerty: true) == Shortcut("c", modifiers: [.command]))
        #expect(ActionRegistry().stroke(for: event) == Shortcut("j", modifiers: [.command]))
    }

    @Test func tableCoversEveryLetterOnce() {
        let letters = Set("abcdefghijklmnopqrstuvwxyz".map(String.init))
        #expect(letters.isSubset(of: Set(Shortcut.qwertyKeys.values)))
        #expect(Shortcut.qwertyKeys.count == Set(Shortcut.qwertyKeys.values).count)
        #expect(Shortcut.qwertyKeys[8] == "c")
    }
}
