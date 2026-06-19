import Testing
@testable import CmuxSettings

@Suite("shortcuts.commands catalog key")
struct CommandShortcutsCatalogKeyTests {
    @Test func commandsKeyHasExpectedIdAndEmptyDefault() {
        let section = KeyboardShortcutsCatalogSection()
        #expect(section.commands.id == "shortcuts.commands")
        #expect(section.commands.defaultValue.isEmpty)
    }

    @Test func commandsValueRoundTripsThroughJSONCodec() {
        let value: [String: StoredShortcut] = [
            "palette.triggerFlash": StoredShortcut(first: ShortcutStroke(key: "1", command: true, shift: true)),
        ]
        let encoded = value.encodeForJSON()
        let decoded = [String: StoredShortcut].decodeFromJSON(encoded)
        #expect(decoded == value)
    }
}
