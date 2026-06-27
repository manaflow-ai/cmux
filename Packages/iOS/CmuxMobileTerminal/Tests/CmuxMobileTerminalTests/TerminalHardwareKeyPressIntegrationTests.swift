#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

// MARK: - UIKit press doubles

/// A `UIKey` whose four read fields the capture path consults
/// (`keyCode`, `modifierFlags`, `characters`, `charactersIgnoringModifiers`) are
/// fully controlled. UIKit never sees this object; only our own `pressesBegan`
/// override reads it, so overriding the public getters fully simulates any
/// physical key chord.
private final class FakeKey: UIKey {
    private let _keyCode: UIKeyboardHIDUsage
    private let _modifierFlags: UIKeyModifierFlags
    private let _characters: String

    init(keyCode: UIKeyboardHIDUsage, modifierFlags: UIKeyModifierFlags, characters: String) {
        _keyCode = keyCode
        _modifierFlags = modifierFlags
        _characters = characters
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused in tests") }

    override var keyCode: UIKeyboardHIDUsage { _keyCode }
    override var modifierFlags: UIKeyModifierFlags { _modifierFlags }
    override var characters: String { _characters }
    override var charactersIgnoringModifiers: String { _characters }
}

/// A `UIPress` that vends a ``FakeKey``. The capture path reads only `press.key`,
/// so `phase`/`type` keep their defaults.
private final class FakePress: UIPress {
    private let _key: UIKey?
    init(key: UIKey?) {
        _key = key
        super.init()
    }
    override var key: UIKey? { _key }
}

private func hexString(_ data: Data) -> String {
    data.map { String(format: "%02X", $0) }.joined(separator: " ")
}

/// One hardware chord → the exact send-sink bytes it must produce (hex).
struct PressCase: Sendable, CustomTestStringConvertible {
    let label: String
    let keyCode: UIKeyboardHIDUsage
    let modifiers: UIKeyModifierFlags
    let characters: String
    let expectedHex: String

    var testDescription: String { "\(label) → \(expectedHex)" }
}

/// The full asserted table (key → exact send-sink bytes, hex). After the fix:
///  - Option+Left/Right emit the readline META word-move bytes `ESC b`/`ESC f`
///    (what macOS terminals send for Option+Arrow and what zsh/bash bind);
///  - Ctrl+Left/Right ALSO collapse to the readline META word-move bytes
///    `ESC b`/`ESC f` (zsh/bash leave the xterm `ESC[1;5D`/`ESC[1;5C` cursor form
///    UNBOUND, so it would self-insert as literal text) — same policy as Option,
///    matching `TerminalKeyEncoder.cursorSequence`;
///  - plain/Shift arrows, Home/Ctrl+Home, and the Ctrl-letter C0 codes are
///    unchanged and correct.
let pressCases: [PressCase] = [
    PressCase(label: "plain Left", keyCode: .keyboardLeftArrow, modifiers: [], characters: "\u{F702}", expectedHex: "1B 5B 44"),
    PressCase(label: "Option+Left", keyCode: .keyboardLeftArrow, modifiers: [.alternate], characters: "\u{F702}", expectedHex: "1B 62"),
    PressCase(label: "Option+Right", keyCode: .keyboardRightArrow, modifiers: [.alternate], characters: "\u{F703}", expectedHex: "1B 66"),
    PressCase(label: "Ctrl+Left", keyCode: .keyboardLeftArrow, modifiers: [.control], characters: "\u{F702}", expectedHex: "1B 62"),
    PressCase(label: "Ctrl+Right", keyCode: .keyboardRightArrow, modifiers: [.control], characters: "\u{F703}", expectedHex: "1B 66"),
    PressCase(label: "Shift+Left", keyCode: .keyboardLeftArrow, modifiers: [.shift], characters: "\u{F702}", expectedHex: "1B 5B 31 3B 32 44"),
    PressCase(label: "Ctrl+C", keyCode: .keyboardC, modifiers: [.control], characters: "c", expectedHex: "03"),
    PressCase(label: "Ctrl+W", keyCode: .keyboardW, modifiers: [.control], characters: "w", expectedHex: "17"),
    PressCase(label: "Ctrl+U", keyCode: .keyboardU, modifiers: [.control], characters: "u", expectedHex: "15"),
    PressCase(label: "Alt+b", keyCode: .keyboardB, modifiers: [.alternate], characters: "b", expectedHex: "1B 62"),
    PressCase(label: "Home", keyCode: .keyboardHome, modifiers: [], characters: "\u{F729}", expectedHex: "1B 5B 48"),
    PressCase(label: "Ctrl+Home", keyCode: .keyboardHome, modifiers: [.control], characters: "\u{F729}", expectedHex: "1B 5B 31 3B 35 7E"),
]

/// Byte-level INTEGRATION tests for the hardware-keyboard capture path.
///
/// These drive a fabricated ``UIPress`` through the real
/// ``TerminalInputTextView/pressesBegan(_:with:)`` path —
/// `pressesBegan` → `handleHardwarePress` → `shouldConsume` →
/// `terminalInput(for:)` (keyCode→input map) → `encodeAndEmitHardwareKey` →
/// ``TerminalHardwareKeyResolver`` → ``TerminalKeyEncoder`` — and assert the
/// EXACT bytes that reach the ``TerminalInputTextView/onEscapeSequence`` send
/// sink (the same bytes `GhosttySurfaceView` forwards verbatim to the Mac
/// transport). Unlike the encoder unit tests, this proves the keyCode mapping,
/// the consume decision, and the emit wiring end to end.
@MainActor
@Suite("TerminalInputTextView hardware-press byte path")
struct TerminalHardwareKeyPressIntegrationTests {
    /// Drive one fabricated press through the real capture path and return every
    /// byte block delivered to the send sink (`onEscapeSequence`). A modified
    /// arrow that wrongly fell back to plain text/backspace would surface as a
    /// `TEXT:`/`BACKSPACE` block instead, failing the exact-bytes assertion.
    private func emitted(
        keyCode: UIKeyboardHIDUsage,
        modifiers: UIKeyModifierFlags,
        characters: String
    ) -> [Data] {
        let view = TerminalInputTextView()
        var captured: [Data] = []
        view.onEscapeSequence = { captured.append($0) }
        view.onText = { captured.append(Data("TEXT:\($0)".utf8)) }
        view.onBackspace = { captured.append(Data("BACKSPACE".utf8)) }

        let press = FakePress(key: FakeKey(keyCode: keyCode, modifierFlags: modifiers, characters: characters))
        view.simulateHardwarePressForTesting(press)
        return captured
    }

    @Test("hardware press emits exactly the expected send-sink bytes", arguments: pressCases)
    func pressEmitsExpectedBytes(_ c: PressCase) {
        let blocks = emitted(keyCode: c.keyCode, modifiers: c.modifiers, characters: c.characters)
        #expect(blocks.count == 1, "\(c.label): expected 1 send-sink block, got \(blocks.map(hexString))")
        let actualHex = blocks.first.map(hexString) ?? "<none>"
        #expect(actualHex == c.expectedHex, "\(c.label): expected [\(c.expectedHex)], got [\(actualHex)]")
    }

    // MARK: Targeted regression assertions (the build-4 word-movement bug)

    @Test("Option+Left is ESC b, never the unbound xterm ESC[1;3D")
    func optionLeftIsMetaB() {
        let blocks = emitted(keyCode: .keyboardLeftArrow, modifiers: [.alternate], characters: "\u{F702}")
        #expect(blocks == [Data([0x1B, 0x62])])
        #expect(blocks.first != Data([0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x44]))
    }

    @Test("Option+Right is ESC f, never the unbound xterm ESC[1;3C")
    func optionRightIsMetaF() {
        let blocks = emitted(keyCode: .keyboardRightArrow, modifiers: [.alternate], characters: "\u{F703}")
        #expect(blocks == [Data([0x1B, 0x66])])
        #expect(blocks.first != Data([0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x43]))
    }

    @Test("every modified arrow/nav sequence carries the leading ESC (0x1B)")
    func modifiedSequencesLeadWithEsc() {
        let modified: [(UIKeyboardHIDUsage, UIKeyModifierFlags)] = [
            (.keyboardLeftArrow, [.alternate]), (.keyboardRightArrow, [.alternate]),
            (.keyboardLeftArrow, [.control]), (.keyboardRightArrow, [.control]),
            (.keyboardLeftArrow, [.shift]), (.keyboardHome, [.control]),
        ]
        for (keyCode, mods) in modified {
            let blocks = emitted(keyCode: keyCode, modifiers: mods, characters: "\u{F702}")
            #expect(blocks.first?.first == 0x1B, "keyCode \(keyCode.rawValue) mods \(mods.rawValue) lost its ESC: \(blocks.map(hexString))")
        }
    }

    // MARK: Ctrl+C pre-encoded-ETX regression (real-device dropped-keystroke bug)

    @Test("Ctrl+C resolves from keyCode even when the device pre-encodes ETX (U+0003)")
    func ctrlCEmitsEtxWhenCharsArePreEncoded() {
        // On a physical keyboard, a Control chord can arrive with
        // `charactersIgnoringModifiers` ALREADY collapsed to its C0 byte: Ctrl+C
        // reports U+0003 (ETX), not "c". Reading that pre-encoded scalar fails the
        // encoder's 0x40...0x5F control-letter guard and drops the keystroke (no
        // SIGINT reaches the shell). The capture path must instead resolve the
        // letter from the physical `.keyboardC` keyCode so the encoder still
        // produces ETX (0x03). Ctrl+W/U/A/E only ever worked because the device
        // happened to report their letter; this proves the keyCode fallback.
        let blocks = emitted(keyCode: .keyboardC, modifiers: [.control], characters: "\u{03}")
        #expect(blocks == [Data([0x03])], "Ctrl+C (pre-encoded ETX) must emit 0x03, got \(blocks.map(hexString))")
    }
}
#endif
