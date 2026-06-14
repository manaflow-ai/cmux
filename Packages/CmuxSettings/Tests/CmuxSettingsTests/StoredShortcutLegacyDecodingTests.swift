import Foundation
import Testing
@testable import CmuxSettings

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5422.
///
/// `StoredShortcut` used to persist as flat fields (`key`, `command`, …,
/// `chordKey`, …). The move to nested ``ShortcutStroke``s (`first` / `second`)
/// in the settings-package reimplement changed the serialized shape without a
/// legacy decoder, so every keyboard shortcut a user had customized failed to
/// decode and silently reverted to its default. These fixtures are the real
/// pre-0.64.11 on-disk JSON (`JSONEncoder` omits nil optionals) and must keep
/// decoding into the equivalent nested value.
@Suite("StoredShortcut legacy decoding")
struct StoredShortcutLegacyDecodingTests {
    private func decode(_ json: String) throws -> StoredShortcut {
        try JSONDecoder().decode(StoredShortcut.self, from: Data(json.utf8))
    }

    @Test func decodesLegacySingleStroke() throws {
        // ⌘T as persisted by cmux ≤ 0.64.10.
        let decoded = try decode(
            #"{"key":"t","command":true,"shift":false,"option":false,"control":false,"keyCode":17,"chordCommand":false,"chordShift":false,"chordOption":false,"chordControl":false}"#
        )
        #expect(decoded.first == ShortcutStroke(key: "t", command: true, keyCode: 17))
        #expect(decoded.second == nil)
        #expect(!decoded.isUnbound)
    }

    @Test func decodesLegacyChord() throws {
        // A tmux-style chord (Ctrl-B then C) as persisted by cmux ≤ 0.64.10.
        let decoded = try decode(
            #"{"key":"b","command":false,"shift":false,"option":false,"control":true,"keyCode":11,"chordKey":"c","chordCommand":false,"chordShift":false,"chordOption":false,"chordControl":false,"chordKeyCode":8}"#
        )
        #expect(decoded.first == ShortcutStroke(key: "b", control: true, keyCode: 11))
        #expect(decoded.second == ShortcutStroke(key: "c", keyCode: 8))
        #expect(decoded.hasChord)
    }

    @Test func decodesLegacyUnbound() throws {
        // An explicit "no shortcut" binding as persisted by cmux ≤ 0.64.10.
        let decoded = try decode(
            #"{"key":"","command":false,"shift":false,"option":false,"control":false,"chordCommand":false,"chordShift":false,"chordOption":false,"chordControl":false}"#
        )
        #expect(decoded.isUnbound)
    }

    @Test func decodeFromUserDefaultsRecoversLegacyData() {
        // The runtime reads persisted shortcuts via this path; it must recover
        // legacy data instead of returning nil (which reverts to the default).
        let json =
            #"{"key":"t","command":true,"shift":false,"option":false,"control":false,"keyCode":17,"chordCommand":false,"chordShift":false,"chordOption":false,"chordControl":false}"#
        let recovered = StoredShortcut.decodeFromUserDefaults(Data(json.utf8))
        #expect(recovered == StoredShortcut(first: ShortcutStroke(key: "t", command: true, keyCode: 17)))
    }

    @Test func newNestedFormatStillRoundTrips() throws {
        // The legacy fallback must not regress the current nested format.
        let original = StoredShortcut(
            first: ShortcutStroke(key: "p", command: true, shift: true, keyCode: 35),
            second: ShortcutStroke(key: "k", keyCode: 40)
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(StoredShortcut.self, from: data) == original)
    }
}
