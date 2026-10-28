import AppKit
import Carbon.HIToolbox
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocusUI
@testable import CmuxNextTerminal
import Testing

/// Ghostty's physical-key keybinds become binding table entries named by what the layout types
/// (`KeyCodeLayout.keyNames(typed:)`), and a key-down reads in Ghostty's order
/// (`ActionRegistry.shortcuts(for:)`). Both must agree on every layout:
/// - Ghostty's default `super+digit_N` (goto_tab) is named by its digit, so on AZERTY it is the
///   Cmd-1 entry that cmux's own Cmd-1 default beats, never a Cmd-& entry that the typed & reads
///   first (Cmd-& selected tab 1 instead of workspace 1);
/// - a physical keybind with Command is named by the layout's Command key map, the only reading a
///   Command key has there (`super+key_t` on Russian is Cmd-T, not Cmd-е).
@MainActor @Suite struct GhosttyKeyNamesLayoutTests {
    /// AZERTY's main-row characters on the digit row and its swapped letters.
    static let azerty: [(code: UInt16, key: String)] = [
        (18, "&"), (19, "é"), (20, "\""), (21, "'"), (23, "("), (22, "§"), (26, "è"), (28, "!"), (25, "ç"), (29, "à"),
        (12, "a"), (0, "q"), (13, "z"), (6, "w"), (41, "m"),
    ]

    /// Russian's plain letters on the US letter keys it types them on.
    static let russian: [(code: UInt16, key: String)] = [
        (12, "й"), (13, "ц"), (14, "у"), (15, "к"), (17, "е"), (16, "н"), (32, "г"), (34, "ш"), (31, "щ"), (35, "з"),
        (0, "ф"), (1, "ы"), (2, "в"), (3, "а"), (5, "п"), (4, "р"), (38, "о"), (40, "л"), (37, "д"), (6, "я"), (7, "ч"),
        (8, "с"), (9, "м"), (11, "и"), (45, "т"), (46, "ь"),
    ]

    static func entry(_ bind: GhosttyHostKeybind, keyNames: [UInt16: String], commandKeyNames: [UInt16: String]? = nil) -> Shortcut? {
        GhosttyKeyBindingLayer(binds: [bind], defaults: [], keyNames: keyNames, commandKeyNames: commandKeyNames).entries.first?.keys.first
    }

    @Test(arguments: 1...8)
    func aGhosttyDigitKeybindIsNamedByItsDigitOnAZERTY(digit: Int) throws {
        let codes: [Int: UInt16] = [1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28]
        let code = try #require(codes[digit])
        let bind = GhosttyHostKeybind(key: .keyCode(code), modifiers: [.command], action: .gotoTab(.index(digit)))
        let names = KeyCodeLayout.keyNames(typed: Self.azerty)
        #expect(Self.entry(bind, keyNames: names) == Shortcut(String(digit), modifiers: [.command]))
    }

    /// Letters are still named by what the layout types (Ghostty's `key_q` is the key that types a on AZERTY).
    @Test func lettersKeepTheirLayoutName() {
        let bind = GhosttyHostKeybind(key: .keyCode(UInt16(kVK_ANSI_Q)), modifiers: [.command, .shift], action: .newWindow)
        #expect(Self.entry(bind, keyNames: KeyCodeLayout.keyNames(typed: Self.azerty)) == Shortcut("a", modifiers: [.command, .shift]))
    }

    @Test func aCommandKeybindIsNamedByTheCommandKeyMap() {
        let bind = GhosttyHostKeybind(key: .keyCode(UInt16(kVK_ANSI_T)), modifiers: [.command, .control], action: .newTab)
        let plain = KeyCodeLayout.keyNames(typed: Self.russian)
        let command = KeyCodeLayout.keyNames(typed: [])
        #expect(Self.entry(bind, keyNames: plain, commandKeyNames: command) == Shortcut("t", modifiers: [.command, .control]))
        // A Control chord has no Command map: the plain name, which a Control key reads first.
        let control = GhosttyHostKeybind(key: .keyCode(UInt16(kVK_ANSI_T)), modifiers: [.control, .shift], action: .newTab)
        #expect(Self.entry(control, keyNames: plain, commandKeyNames: command) == Shortcut("е", modifiers: [.control, .shift]))
    }
}
