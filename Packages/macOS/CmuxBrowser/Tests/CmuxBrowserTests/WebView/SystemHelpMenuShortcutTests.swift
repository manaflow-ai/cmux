import AppKit
import Testing
@testable import CmuxBrowser

@Suite("System Help menu shortcut")
struct SystemHelpMenuShortcutTests {
    private static let commandShiftRawValue = NSEvent.ModifierFlags([.command, .shift]).rawValue

    private static func hotKeys(enabled: Bool, keyCode: Int, modifiers: UInt) -> [String: Any] {
        [
            "98": [
                "enabled": enabled,
                "value": [
                    "parameters": [47, keyCode, modifiers] as [Any],
                    "type": "standard",
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    private static func keyDown(
        keyCode: UInt16,
        characters: String,
        modifierFlags: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifierFlags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    @Test func missingEntryUsesAppKitDefault() {
        #expect(SystemHelpMenuShortcut.resolve(symbolicHotKeys: nil) == .appKitDefault)
        #expect(SystemHelpMenuShortcut.resolve(symbolicHotKeys: [:]) == .appKitDefault)
        #expect(SystemHelpMenuShortcut.appKitDefault == SystemHelpMenuShortcut(keyCode: 44, modifierFlags: [.command, .shift]))
    }

    @Test func readsRemappedBinding() {
        let shortcut = SystemHelpMenuShortcut.resolve(
            symbolicHotKeys: Self.hotKeys(enabled: true, keyCode: 4, modifiers: Self.commandShiftRawValue)
        )
        #expect(shortcut == SystemHelpMenuShortcut(keyCode: 4, modifierFlags: [.command, .shift]))
    }

    @Test func disabledBindingResolvesToNil() {
        let shortcut = SystemHelpMenuShortcut.resolve(
            symbolicHotKeys: Self.hotKeys(enabled: false, keyCode: 44, modifiers: Self.commandShiftRawValue)
        )
        #expect(shortcut == nil)
    }

    @Test func matchesOnlyTheExactChord() {
        let shortcut = SystemHelpMenuShortcut.appKitDefault
        #expect(shortcut.matches(keyCode: 44, modifierFlags: [.command, .shift]))
        #expect(shortcut.matches(keyCode: 44, modifierFlags: [.command, .shift, .capsLock]))
        #expect(!shortcut.matches(keyCode: 44, modifierFlags: [.command]))
        #expect(!shortcut.matches(keyCode: 44, modifierFlags: [.command, .shift, .option]))
        #expect(!shortcut.matches(keyCode: 43, modifierFlags: [.command, .shift]))
    }

    // Regression for #21230: cmux sent Cmd+Shift+/ to the main menu and then to
    // the terminal, which consumed it before AppKit could open Help menu search.
    @Test func helpMenuChordStaysWithAppKit() throws {
        let event = try Self.keyDown(keyCode: 44, characters: "?", modifierFlags: [.command, .shift])
        #expect(!event.cmuxRoutesDirectlyToMainMenu(windowCyclingShortcut: .appKitDefault, helpMenuShortcut: .appKitDefault))
    }

    @Test func helpMenuChordRoutesToMainMenuWhenDisabled() throws {
        let event = try Self.keyDown(keyCode: 44, characters: "?", modifierFlags: [.command, .shift])
        #expect(event.cmuxRoutesDirectlyToMainMenu(windowCyclingShortcut: .appKitDefault, helpMenuShortcut: nil))
    }

    @Test func otherSlashChordsStillRouteToMainMenu() throws {
        let commandSlash = try Self.keyDown(keyCode: 44, characters: "/", modifierFlags: [.command])
        let commandOptionShiftSlash = try Self.keyDown(keyCode: 44, characters: "?", modifierFlags: [.command, .option, .shift])
        #expect(commandSlash.cmuxRoutesDirectlyToMainMenu(windowCyclingShortcut: .appKitDefault, helpMenuShortcut: .appKitDefault))
        #expect(commandOptionShiftSlash.cmuxRoutesDirectlyToMainMenu(windowCyclingShortcut: .appKitDefault, helpMenuShortcut: .appKitDefault))
    }
}
