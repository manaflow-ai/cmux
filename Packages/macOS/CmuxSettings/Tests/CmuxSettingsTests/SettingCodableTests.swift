import Foundation
import Testing
@testable import CmuxSettings

@Suite("SettingCodable")
struct SettingCodableTests {
    @Test func boolDecodesFromNSNumberBoolean() {
        #expect(Bool.decodeFromUserDefaults(NSNumber(value: true)) == true)
        // JSON keeps the bool/int distinction; UserDefaults does not.
        #expect(Bool.decodeFromJSON(NSNumber(value: 1)) == nil)
    }

    @Test func intDistinguishesBooleanFromIntInJSON() {
        #expect(Int.decodeFromJSON(NSNumber(value: true)) == nil)
        #expect(Int.decodeFromJSON(NSNumber(value: 42)) == 42)
    }

    @Test func intFromJSONRejectsFractional() {
        #expect(Int.decodeFromJSON(NSNumber(value: 1.5)) == nil)
        #expect(Int.decodeFromJSON(NSNumber(value: 7)) == 7)
    }

    @Test func rawRepresentableEnumRoundTrips() {
        let encoded = AppearanceMode.dark.encodeForJSON()
        #expect(encoded as? String == "dark")
        #expect(AppearanceMode.decodeFromJSON(encoded) == .dark)
    }

    @Test func arrayRoundTrip() {
        let value: [String] = ["a", "b"]
        let encoded = value.encodeForJSON()
        #expect([String].decodeFromJSON(encoded) == value)
    }

    @Test func dictionaryRoundTrip() {
        let value: [String: Int] = ["x": 1, "y": 2]
        let encoded = value.encodeForJSON()
        #expect([String: Int].decodeFromJSON(encoded) == value)
    }

    // MARK: - StoredShortcut decodes every schema-valid binding form

    @Test func storedShortcutObjectFormRoundTrips() {
        let value = StoredShortcut(first: ShortcutStroke(key: "n", command: true))
        #expect(StoredShortcut.decodeFromJSON(value.encodeForJSON()) == value)
    }

    @Test func storedShortcutDecodesStringStroke() {
        // The string form must yield the same canonical key ("↓", …) the
        // runtime resolver uses, so UI-loaded and runtime bindings agree.
        #expect(
            StoredShortcut.decodeFromJSON("cmd+shift+down")
                == StoredShortcut(first: ShortcutStroke(key: "↓", command: true, shift: true))
        )
        #expect(
            StoredShortcut.decodeFromJSON("ctrl+a")
                == StoredShortcut(first: ShortcutStroke(key: "a", control: true))
        )
    }

    @Test func storedShortcutDecodesChordArray() {
        #expect(
            StoredShortcut.decodeFromJSON(["ctrl+b", "c"])
                == StoredShortcut(
                    first: ShortcutStroke(key: "b", control: true),
                    second: ShortcutStroke(key: "c")
                )
        )
    }

    @Test func storedShortcutDecodesUnbindSentinels() {
        for token in ["", "none", "clear", "unbound", "disabled"] {
            #expect(StoredShortcut.decodeFromJSON(token) == .unbound, "\(token) should decode to unbound")
        }
        #expect(StoredShortcut.decodeFromJSON(NSNull()) == .unbound)
        #expect(StoredShortcut.decodeFromJSON([String]()) == .unbound)
    }

    @Test func storedShortcutRejectsInvalidString() {
        #expect(StoredShortcut.decodeFromJSON("cmd+boguskey") == nil)
        #expect(StoredShortcut.decodeFromJSON("madeupmodifier+a") == nil)
    }

    @Test func bindingsDictionarySurvivesMixedForms() {
        // The all-or-nothing dictionary decode must no longer blank the whole
        // map when one entry is a hand-authored string form and another is the
        // object form the UI writes — this was the root of the clobber bug.
        let objectForm = StoredShortcut(first: ShortcutStroke(key: ",", command: true)).encodeForJSON()
        let raw: [String: Any] = ["focusDown": "cmd+shift+down", "openSettings": objectForm]
        let decoded = [String: StoredShortcut].decodeFromJSON(raw)
        #expect(decoded?["focusDown"] == StoredShortcut(first: ShortcutStroke(key: "↓", command: true, shift: true)))
        #expect(decoded?["openSettings"] == StoredShortcut(first: ShortcutStroke(key: ",", command: true)))
    }
}
