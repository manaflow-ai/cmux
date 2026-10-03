import AppKit
import Testing
@testable import CmuxBrowser

@Suite("System window cycling shortcut")
struct SystemWindowCyclingShortcutTests {
    private static let commandRawValue = NSEvent.ModifierFlags.command.rawValue

    private static func hotKeys(enabled: Bool, keyCode: Int, modifiers: UInt) -> [String: Any] {
        [
            "27": [
                "enabled": enabled,
                "value": [
                    "parameters": [167, keyCode, modifiers] as [Any],
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
        #expect(SystemWindowCyclingShortcut.resolve(symbolicHotKeys: nil) == .appKitDefault)
        #expect(SystemWindowCyclingShortcut.resolve(symbolicHotKeys: [:]) == .appKitDefault)
    }

    @Test func readsISOSectionKeyBinding() {
        let shortcut = SystemWindowCyclingShortcut.resolve(
            symbolicHotKeys: Self.hotKeys(enabled: true, keyCode: 10, modifiers: Self.commandRawValue)
        )
        #expect(shortcut == SystemWindowCyclingShortcut(keyCode: 10, modifierFlags: [.command]))
    }

    @Test func disabledBindingResolvesToNil() {
        let shortcut = SystemWindowCyclingShortcut.resolve(
            symbolicHotKeys: Self.hotKeys(enabled: false, keyCode: 10, modifiers: Self.commandRawValue)
        )
        #expect(shortcut == nil)
    }

    @Test func matchesForwardAndShiftedBackward() {
        let shortcut = SystemWindowCyclingShortcut(keyCode: 10, modifierFlags: [.command])
        #expect(shortcut.matches(keyCode: 10, modifierFlags: [.command]))
        #expect(shortcut.matches(keyCode: 10, modifierFlags: [.command, .shift]))
        #expect(!shortcut.matches(keyCode: 10, modifierFlags: [.command, .option]))
        #expect(!shortcut.matches(keyCode: 50, modifierFlags: [.command]))
    }

    @Test func bindingStoredWithFunctionFlagMatchesItsKey() {
        let shortcut = SystemWindowCyclingShortcut(keyCode: 97, modifierFlags: [.command, .function])
        #expect(shortcut.matches(keyCode: 97, modifierFlags: [.command, .function]))
        #expect(shortcut.matches(keyCode: 97, modifierFlags: [.command]))
    }

    // Regression: on ISO keyboards the window-cycling key is the section key
    // (keyCode 10). cmux used to route it to the main menu and then to the
    // terminal, which consumed it before AppKit could cycle windows.
    @Test func isoSectionKeyStaysWithAppKitWhenItCyclesWindows() throws {
        let shortcut = SystemWindowCyclingShortcut(keyCode: 10, modifierFlags: [.command])
        let forward = try Self.keyDown(keyCode: 10, characters: "§", modifierFlags: [.command])
        let backward = try Self.keyDown(keyCode: 10, characters: "±", modifierFlags: [.command, .shift])
        #expect(!forward.cmuxRoutesDirectlyToMainMenu(windowCyclingShortcut: shortcut))
        #expect(!backward.cmuxRoutesDirectlyToMainMenu(windowCyclingShortcut: shortcut))
    }

    @Test func otherCommandKeysStillRouteToMainMenu() throws {
        let shortcut = SystemWindowCyclingShortcut(keyCode: 10, modifierFlags: [.command])
        let commandT = try Self.keyDown(keyCode: 17, characters: "t", modifierFlags: [.command])
        let optionSection = try Self.keyDown(keyCode: 10, characters: "§", modifierFlags: [.command, .option])
        #expect(commandT.cmuxRoutesDirectlyToMainMenu(windowCyclingShortcut: shortcut))
        #expect(optionSection.cmuxRoutesDirectlyToMainMenu(windowCyclingShortcut: shortcut))
    }

    // The US backtick keeps its existing exemption whatever the system reports.
    @Test func usBacktickStaysWithAppKit() throws {
        let backtick = try Self.keyDown(keyCode: 50, characters: "`", modifierFlags: [.command])
        #expect(!backtick.cmuxRoutesDirectlyToMainMenu(windowCyclingShortcut: nil))
        #expect(!backtick.cmuxRoutesDirectlyToMainMenu(windowCyclingShortcut: .appKitDefault))
    }
}
