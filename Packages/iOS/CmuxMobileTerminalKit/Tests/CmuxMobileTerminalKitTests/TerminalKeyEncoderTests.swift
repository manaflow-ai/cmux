import Foundation
import Testing
@testable import CmuxMobileTerminalKit

@Suite("TerminalKeyEncoder byte tables")
struct TerminalKeyEncoderTests {
    @Test("special keys encode to exact VT bytes", arguments: [
        (TerminalSpecialKey.upArrow, TerminalKeyModifier(), [0x1B, 0x5B, 0x41]),
        (.downArrow, [], [0x1B, 0x5B, 0x42]),
        (.rightArrow, [], [0x1B, 0x5B, 0x43]),
        (.leftArrow, [], [0x1B, 0x5B, 0x44]),
        (.home, [], [0x1B, 0x5B, 0x48]),
        (.end, [], [0x1B, 0x5B, 0x46]),
        (.pageUp, [], [0x1B, 0x5B, 0x35, 0x7E]),
        (.pageDown, [], [0x1B, 0x5B, 0x36, 0x7E]),
        (.delete, [], [0x1B, 0x5B, 0x33, 0x7E]),
        (.escape, [], [0x1B]),
        (.tab, [], [0x09]),
        (.tab, [.shift], [0x1B, 0x5B, 0x5A]),
        // Option+Backspace word-delete special case (preserved): Alt+forward-delete = ESC DEL.
        (.delete, [.alternate], [0x1B, 0x7F]),
        // Modified arrows — xterm CSI 1;m matrix (m = 1 + shift + alt*2 + ctrl*4).
        (.upArrow, [.shift], [0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x41]),              // Shift+Up = ESC[1;2A
        (.leftArrow, [.shift], [0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x44]),            // Shift+Left = ESC[1;2D
        // Ctrl+Left/Right AND Option+Left/Right both emit the readline META
        // word-move bytes (ESC b / ESC f), NOT the xterm cursor CSI form — zsh/bash
        // leave both ESC[1;5D/C (Ctrl) and ESC[1;3D/C (Alt) unbound and echo them
        // literally ("[1;5D"), the real-device regression.
        (.leftArrow, [.alternate], [0x1B, 0x62]),                                // Option+Left = ESC b (backward-word)
        (.rightArrow, [.alternate], [0x1B, 0x66]),                               // Option+Right = ESC f (forward-word)
        (.leftArrow, [.control], [0x1B, 0x62]),                                  // Ctrl+Left = ESC b (backward-word)
        (.rightArrow, [.control], [0x1B, 0x66]),                                 // Ctrl+Right = ESC f (forward-word)
        (.rightArrow, [.control, .shift], [0x1B, 0x66]),                         // Ctrl+Shift+Right = ESC f (word-move)
        (.upArrow, [.control, .alternate], [0x1B, 0x5B, 0x31, 0x3B, 0x37, 0x41]),// Ctrl+Alt+Up = ESC[1;7A (vertical stays xterm)
        // Modified nav keys — xterm CSI n;m~ matrix.
        (.home, [.control], [0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x7E]),               // Ctrl+Home = ESC[1;5~
        (.end, [.shift], [0x1B, 0x5B, 0x34, 0x3B, 0x32, 0x7E]),                  // Shift+End = ESC[4;2~
        (.pageUp, [.control], [0x1B, 0x5B, 0x35, 0x3B, 0x35, 0x7E]),             // Ctrl+PgUp = ESC[5;5~
        (.pageDown, [.shift], [0x1B, 0x5B, 0x36, 0x3B, 0x32, 0x7E]),             // Shift+PgDn = ESC[6;2~
        (.delete, [.control], [0x1B, 0x5B, 0x33, 0x3B, 0x35, 0x7E]),             // Ctrl+Delete = ESC[3;5~
    ] as [(TerminalSpecialKey, TerminalKeyModifier, [UInt8])])
    func specialKeys(key: TerminalSpecialKey, modifiers: TerminalKeyModifier, expected: [UInt8]) {
        #expect(TerminalKeyEncoder.encode(specialKey: key, modifiers: modifiers) == Data(expected))
    }

    @Test("undefined special-key combinations return nil")
    func undefinedSpecial() {
        // Escape has no modified form; Tab defines only plain + Shift (back-tab).
        // Arrows/nav keys are otherwise defined by the CSI modifier matrix.
        #expect(TerminalKeyEncoder.encode(specialKey: .escape, modifiers: [.shift]) == nil)
        #expect(TerminalKeyEncoder.encode(specialKey: .escape, modifiers: [.control]) == nil)
        #expect(TerminalKeyEncoder.encode(specialKey: .tab, modifiers: [.control]) == nil)
        #expect(TerminalKeyEncoder.encode(specialKey: .tab, modifiers: [.alternate]) == nil)
        // Option+Up/Down have no META word-move; emitting the xterm ESC[1;3A/B
        // form would echo literally in zsh/bash, so they are suppressed (no-op).
        #expect(TerminalKeyEncoder.encode(specialKey: .upArrow, modifiers: [.alternate]) == nil)
        #expect(TerminalKeyEncoder.encode(specialKey: .downArrow, modifiers: [.alternate]) == nil)
    }

    @Test("word-move arrows never emit the shell-unbound xterm cursor form")
    func wordMoveArrowsAreMetaNotXtermCSI() {
        // Regression guard for the real-device literal-"[1;3D"/"[1;5D" bug.
        // Option word-move = ESC b / ESC f, never the xterm Alt-cursor CSI form.
        #expect(TerminalKeyEncoder.encode(specialKey: .leftArrow, modifiers: [.alternate]) == Data([0x1B, 0x62]))
        #expect(TerminalKeyEncoder.encode(specialKey: .rightArrow, modifiers: [.alternate]) == Data([0x1B, 0x66]))
        #expect(TerminalKeyEncoder.encode(specialKey: .leftArrow, modifiers: [.alternate]) != Data([0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x44]))
        #expect(TerminalKeyEncoder.encode(specialKey: .rightArrow, modifiers: [.alternate]) != Data([0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x43]))
        // Ctrl word-move collapses to the SAME META bytes, never the xterm
        // Ctrl-cursor CSI form (ESC[1;5D / ESC[1;5C) that zsh/bash echo literally.
        #expect(TerminalKeyEncoder.encode(specialKey: .leftArrow, modifiers: [.control]) == Data([0x1B, 0x62]))
        #expect(TerminalKeyEncoder.encode(specialKey: .rightArrow, modifiers: [.control]) == Data([0x1B, 0x66]))
        #expect(TerminalKeyEncoder.encode(specialKey: .leftArrow, modifiers: [.control]) != Data([0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x44]))
        #expect(TerminalKeyEncoder.encode(specialKey: .rightArrow, modifiers: [.control]) != Data([0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x43]))
    }

    @Test("extraneous modifier bits are masked before lookup")
    func masksUnsupportedBits() {
        // A high bit outside the supported set must not change the encoding.
        let stray = TerminalKeyModifier(rawValue: 1 << 20)
        #expect(TerminalKeyEncoder.encode(specialKey: .upArrow, modifiers: stray) == Data([0x1B, 0x5B, 0x41]))
    }

    @Test("control letters map to control bytes", arguments: [
        ("a", UInt8(0x01)), ("c", 0x03), ("d", 0x04), ("z", 0x1A),
        ("A", 0x01), ("Z", 0x1A), ("[", 0x1B), ("]", 0x1D), ("\\", 0x1C),
    ])
    func controlLetters(input: String, expected: UInt8) {
        #expect(TerminalKeyEncoder.encode(character: input, modifiers: [.control]) == Data([expected]))
    }

    @Test("control numeric and symbolic aliases", arguments: [
        (" ", UInt8(0x00)), ("2", 0x00), ("3", 0x1B), ("4", 0x1C),
        ("5", 0x1D), ("6", 0x1E), ("7", 0x1F), ("/", 0x1F), ("?", 0x7F),
    ])
    func controlAliases(input: String, expected: UInt8) {
        #expect(TerminalKeyEncoder.controlCharacter(for: input) == Data([expected]))
    }

    @Test("control+shift still resolves the control byte")
    func controlShift() {
        #expect(TerminalKeyEncoder.encode(character: "@", modifiers: [.control, .shift]) == Data([0x00]))
        #expect(TerminalKeyEncoder.encode(character: "^", modifiers: [.control, .shift]) == Data([0x1E]))
        #expect(TerminalKeyEncoder.encode(character: "_", modifiers: [.control, .shift]) == Data([0x1F]))
        #expect(TerminalKeyEncoder.encode(character: "?", modifiers: [.control, .shift]) == Data([0x7F]))
    }

    @Test("unmodified character returns nil (keyboard inserts it directly)")
    func unmodifiedCharacterNil() {
        #expect(TerminalKeyEncoder.encode(character: "a", modifiers: []) == nil)
        // Shift-only is still plain text the soft keyboard inserts directly.
        #expect(TerminalKeyEncoder.encode(character: "a", modifiers: [.shift]) == nil)
    }

    @Test("alt/option letters encode to meta (ESC + char)", arguments: [
        ("b", [UInt8(0x1B), 0x62]), ("f", [0x1B, 0x66]), ("d", [0x1B, 0x64]),
    ])
    func altLetters(input: String, expected: [UInt8]) {
        #expect(TerminalKeyEncoder.encode(character: input, modifiers: [.alternate]) == Data(expected))
    }

    @Test("ctrl+alt letters encode to ESC then the control byte")
    func ctrlAltLetters() {
        #expect(TerminalKeyEncoder.encode(character: "c", modifiers: [.control, .alternate]) == Data([0x1B, 0x03]))
        #expect(TerminalKeyEncoder.encode(character: "w", modifiers: [.control, .alternate]) == Data([0x1B, 0x17]))
    }

    @Test("alt-prefixed text prepends ESC")
    func altPrefixed() {
        #expect(TerminalKeyEncoder.altPrefixed("b") == Data([0x1B, 0x62]))
        #expect(TerminalKeyEncoder.altPrefixed("hi") == Data([0x1B, 0x68, 0x69]))
        #expect(TerminalKeyEncoder.altPrefixed("") == nil)
    }

    @Test("command readline shortcuts", arguments: [
        ("a", UInt8(0x01)), ("e", 0x05), ("k", 0x0B), ("u", 0x15),
        ("w", 0x17), ("l", 0x0C), ("c", 0x03), ("d", 0x04),
        ("A", 0x01), ("E", 0x05),
    ])
    func commandReadline(input: String, expected: UInt8) {
        #expect(TerminalKeyEncoder.commandReadline(for: input) == Data([expected]))
    }

    @Test("unmapped command readline returns nil")
    func commandReadlineNil() {
        #expect(TerminalKeyEncoder.commandReadline(for: "z") == nil)
        #expect(TerminalKeyEncoder.commandReadline(for: "ab") == nil)
    }
}
