import CmuxFoundation
import Testing

@Suite
struct SidebarMarkdownRendererTests {
    @Test(arguments: [
        ("**Pi finished.**", "Pi finished."),
        ("*Italic* and **bold**", "Italic and bold"),
        ("Run `swift test`", "Run swift test"),
        ("Read [the results](https://example.com)", "Read the results"),
        ("**Done**\n\n*All checks passed*", "Done\n\nAll checks passed"),
        ("  **Done**\t next  ", "  Done\t next  "),
        ("**完成 🎉**", "完成 🎉"),
        (#"\*\*literal\*\*"#, "**literal**"),
        ("`**literal**`", "**literal**"),
        ("CMUX_NOTIFICATION_BODY and src/my_file.swift", "CMUX_NOTIFICATION_BODY and src/my_file.swift"),
        ("**unfinished", "**unfinished"),
        ("", ""),
    ])
    func plainTextPreservesContentWithoutInlineFormatting(content: (String, String)) {
        let (markdown, expected) = content
        #expect(SidebarMarkdownRenderer(markdown: markdown).plainText == expected)
    }
}
