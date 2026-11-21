import Testing
@testable import CmuxSettings

@Suite("ShortcutDisplayFormatter")
struct ShortcutDisplayFormatterTests {
    @Test func displaysTabKeysLegibly() {
        let formatter = ShortcutDisplayFormatter()

        #expect(formatter.keyDisplayString("\t") == "Tab")
        #expect(formatter.keyDisplayString("tab") == "Tab")
        #expect(formatter.strokeDisplayString(
            key: "\t",
            command: false,
            shift: true,
            option: false,
            control: false
        ) == "⇧Tab")
    }

    @Test func displaysEscapeAsTheEscapeGlyph() {
        let formatter = ShortcutDisplayFormatter()

        #expect(formatter.keyDisplayString("escape") == "⎋")
        #expect(formatter.strokeDisplayString(
            key: "escape",
            command: true,
            shift: false,
            option: false,
            control: false
        ) == "⌘⎋")
    }
}
