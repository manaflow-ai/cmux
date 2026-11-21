@testable import CmuxNextTerminal
import Foundation
import Testing

struct GhosttyConfigFontFamilyTests {
    @Test func allFontFamiliesFollowGhosttyOrderAndReset() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "font-family-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = directory.appending(path: "config")
        let include = directory.appending(path: "include")
        try "font-family = \"Iosevka\"\nfont-family = \"Menlo\"\n".write(to: base, atomically: true, encoding: .utf8)
        try "# the include wins\nfont-family = \"\"\nfont-family = \"Noto Sans Mono CJK JP\"\n".write(to: include, atomically: true, encoding: .utf8)

        #expect(GhosttyConfigFontFamily.families(inFiles: [base.path, include.path]) == ["Noto Sans Mono CJK JP"])
        #expect(GhosttyConfigFontFamily.family(inFiles: [base.path, include.path]) == "Noto Sans Mono CJK JP")
    }

    @Test func unrelatedLinesAndCommentsDoNotBecomeFontFamilies() {
        let text = """
        font-size = 13
        # font-family = \"Comment\"
        font-family = Iosevka
        other-font-family = \"Nope\"
        """
        #expect(GhosttyConfigFontFamily.fontFamilies(configText: text) == ["Iosevka"])
    }

    @Test func quotedFamilyNamesDecodeGhosttyEscapes() {
        let text = #"font-family = "Quote \"Mono\" \\ Wide""#
        #expect(GhosttyConfigFontFamily.fontFamilies(configText: text) == ["Quote \"Mono\" \\ Wide"])
    }
}
