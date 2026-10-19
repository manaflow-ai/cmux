import Testing
@testable import CmuxTerminalImport

@Suite("Diffing imported settings against cmux's Ghostty config")
struct GhosttyConfigDifferTests {
    let differ = GhosttyConfigDiffer()

    @Test("lists every old assignment of a key, then the new lines, and marks unchanged keys")
    func diff() {
        let existing = """
        # my settings
        font-family = Menlo
        font-family = Apple Color Emoji
        sidebar-font-size = 13
        font-size = 13

        """
        let diff = differ.diff(
            [
                .init(key: "font-family", values: ["\"\"", "\"JetBrains Mono\""]),
                .init(key: "font-size", value: "13"),
                .init(key: "cursor-style", value: "bar"),
            ],
            against: existing
        )

        #expect(diff.diffLines == [
            "- font-family = Menlo",
            "- font-family = Apple Color Emoji",
            "+ font-family = \"\"",
            "+ font-family = \"JetBrains Mono\"",
            "  font-size = 13",
            "+ cursor-style = bar",
        ])
        #expect(diff.hasChanges)
    }

    @Test("a CRLF config's values carry no stray carriage return")
    func crlf() {
        let diff = differ.diff(
            [.init(key: "font-size", value: "14"), .init(key: "theme-free", value: "x")],
            against: "font-size = 13\r\ntheme = Dracula\r\n"
        )
        #expect(diff.changes.first?.oldValues == ["13"])
        #expect(diff.changes.last?.oldValues == [])
    }

    @Test("an already-imported reset plus family counts as unchanged")
    func unchangedFontList() {
        let diff = differ.diff(
            [.init(key: "font-family", values: ["\"\"", "\"Fira Code\""])],
            against: "font-family = \"\"\nfont-family = \"Fira Code\"\n"
        )
        #expect(!diff.hasChanges)
        #expect(diff.diffLines == ["  font-family = \"\"", "  font-family = \"Fira Code\""])
    }

    @Test("an empty config shows only additions")
    func emptyConfig() {
        let diff = differ.diff([.init(key: "font-size", value: "14")], against: "")
        #expect(diff.diffLines == ["+ font-size = 14"])
    }
}
