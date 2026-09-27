import Testing
@testable import CmuxTerminalImport

@Suite("Patching cmux's Ghostty config")
struct GhosttyConfigPatcherTests {
    let patcher = GhosttyConfigPatcher()

    @Test("replaces the first assignment in place, drops repeats, appends new keys under a header")
    func patch() {
        let existing = """
        # my settings
        font-family = Menlo
        font-family = Apple Color Emoji
        sidebar-font-size = 13
        font-size = 13

        """
        let patch = patcher.apply(
            [
                .init(key: "font-family", value: "\"JetBrains Mono\""),
                .init(key: "font-size", value: "13"),
                .init(key: "cursor-style", value: "bar"),
            ],
            to: existing,
            header: "Imported from iTerm2 by cmux import"
        )

        #expect(patch.contents == """
        # my settings
        font-family = "JetBrains Mono"
        sidebar-font-size = 13
        font-size = 13

        # Imported from iTerm2 by cmux import
        cursor-style = bar

        """)
        #expect(patch.diffLines == [
            "- font-family = Menlo",
            "- font-family = Apple Color Emoji",
            "+ font-family = \"JetBrains Mono\"",
            "  font-size = 13",
            "+ cursor-style = bar",
        ])
        #expect(patch.hasChanges)
    }

    @Test("a CRLF config keeps CRLF and its values carry no stray carriage return")
    func crlf() {
        let patch = patcher.apply(
            [.init(key: "font-size", value: "14"), .init(key: "cursor-style", value: "bar")],
            to: "font-size = 13\r\ntheme = Dracula\r\n",
            header: "Imported"
        )
        #expect(patch.changes.first?.oldValues == ["13"])
        #expect(patch.contents == "font-size = 14\r\ntheme = Dracula\r\n\r\n# Imported\r\ncursor-style = bar\r\n")
    }

    @Test("an empty config gets just the header and settings")
    func emptyConfig() {
        let patch = patcher.apply([.init(key: "font-size", value: "14")], to: "", header: "Imported")
        #expect(patch.contents == "# Imported\nfont-size = 14\n")
    }

    @Test("re-applying the same settings changes nothing")
    func idempotent() {
        let settings = [GhosttyConfigSetting(key: "font-size", value: "14")]
        let first = patcher.apply(settings, to: "", header: "Imported")
        let second = patcher.apply(settings, to: first.contents, header: "Imported")
        #expect(second.contents == first.contents)
        #expect(!second.hasChanges)
    }
}
