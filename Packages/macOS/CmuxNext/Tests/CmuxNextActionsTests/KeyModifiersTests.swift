import AppKit
@testable import CmuxNextActions
import Testing

/// ``KeyModifiers`` is the platform-neutral copy of the four shortcut bits of
/// `NSEvent.ModifierFlags`: same raw values (binding-table order, stored
/// family modifiers and action-surfaces.json stay byte-identical), and the
/// AppKit edge converts both ways without loss.
@MainActor @Suite struct KeyModifiersTests {
    @Test func eachBitHasTheAppKitRawValue() {
        #expect(KeyModifiers.shift.rawValue == NSEvent.ModifierFlags.shift.rawValue)
        #expect(KeyModifiers.control.rawValue == NSEvent.ModifierFlags.control.rawValue)
        #expect(KeyModifiers.option.rawValue == NSEvent.ModifierFlags.option.rawValue)
        #expect(KeyModifiers.command.rawValue == NSEvent.ModifierFlags.command.rawValue)
        #expect(KeyModifiers.relevant.rawValue == NSEvent.ModifierFlags([.command, .shift, .option, .control]).rawValue)
    }

    @Test func eventFlagsKeepOnlyTheShortcutBits() {
        let flags: NSEvent.ModifierFlags = [.command, .shift, .capsLock, .function, .numericPad, .help]
        #expect(KeyModifiers(eventFlags: flags) == [.command, .shift])
        #expect(KeyModifiers(eventFlags: []) == [])
        let all: [KeyModifiers] = [[], [.command], [.control, .option], .relevant]
        for modifiers in all {
            #expect(KeyModifiers(eventFlags: modifiers.eventFlags) == modifiers)
        }
    }

    @Test func aShortcutDropsNothingButIgnoredBits() {
        let shortcut = Shortcut("K", modifiers: [.command, .option])
        #expect(shortcut.key == "k")
        #expect(shortcut.modifiers == [.command, .option])
        #expect(shortcut == Shortcut("k", modifiers: [.option, .command]))
        #expect(shortcut != Shortcut("k", modifiers: [.command]))
        #expect(Shortcut("k").modifiers == .command)
    }

    @Test func namedKeyCodesAreTheAppKitFunctionKeys() throws {
        func key(_ code: Int) throws -> String { String(Character(try #require(UnicodeScalar(UInt32(code))))) }
        #expect(try key(NSUpArrowFunctionKey) == Shortcut.upArrowKey)
        #expect(try key(NSDownArrowFunctionKey) == Shortcut.downArrowKey)
        #expect(try key(NSLeftArrowFunctionKey) == Shortcut.leftArrowKey)
        #expect(try key(NSRightArrowFunctionKey) == Shortcut.rightArrowKey)
        #expect(try key(NSHomeFunctionKey) == Shortcut.homeKey)
        #expect(try key(NSEndFunctionKey) == Shortcut.endKey)
        #expect(try key(NSPageUpFunctionKey) == Shortcut.pageUpKey)
        #expect(try key(NSPageDownFunctionKey) == Shortcut.pageDownKey)
        #expect(KeyBindingDefaults.pageDown == Shortcut.pageDownKey)
        #expect(KeyBindingDefaults.home == Shortcut.homeKey)
    }

    @Test func aKeyDownMatchesItsShortcut() throws {
        func event(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                          context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                          isARepeat: false, keyCode: 0))
        }
        let shortcut = Shortcut("p", modifiers: [.command, .shift])
        #expect(shortcut.matches(try event("p", [.command, .shift, .capsLock])))
        #expect(!shortcut.matches(try event("p", [.command])))
        #expect(ActionRegistry.shortcuts(for: try event("p", [.command, .shift, .numericPad])).first == shortcut)
    }
}
