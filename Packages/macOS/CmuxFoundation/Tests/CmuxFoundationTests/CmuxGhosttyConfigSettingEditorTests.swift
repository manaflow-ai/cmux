import Foundation
import Testing
@testable import CmuxFoundation

/// Covers ``CmuxGhosttyConfigSettingEditor`` on CRLF configs: the editor writes
/// the user's Ghostty config, and rewriting one used to append a blank line per
/// write and leave the file with mixed endings.
@Suite("Ghostty config setting editor line handling")
struct CmuxGhosttyConfigSettingEditorTests {
    private let editor = CmuxGhosttyConfigSettingEditor()

    private static let lfConfig = """
    font-family = "SF Mono"
    sidebar-font-size = 12

    """

    /// The same body written with CRLF endings, as a Windows-side editor or a
    /// CRLF-normalizing sync would leave it.
    private static func crlf(_ contents: String) -> String {
        contents.replacingOccurrences(of: "\n", with: "\r\n")
    }

    @Test("Replaces a setting in an LF config without changing anything else")
    func replacesSettingInLFConfig() {
        let updated = editor.updatedContents(
            Self.lfConfig,
            setting: CmuxGhosttyConfigSettingEditor.sidebarFontSizeKey,
            value: "13"
        )

        #expect(updated == """
        font-family = "SF Mono"
        sidebar-font-size = 13

        """)
    }

    @Test("A CRLF config round trip matches the LF round trip line for line")
    func crlfRoundTripMatchesLF() {
        let key = CmuxGhosttyConfigSettingEditor.sidebarFontSizeKey
        let lfUpdated = editor.updatedContents(Self.lfConfig, setting: key, value: "13")
        let crlfUpdated = editor.updatedContents(Self.crlf(Self.lfConfig), setting: key, value: "13")

        // The user's line-ending style survives the write, and nothing else differs:
        // no extra trailing blank line, no line rewritten with the other style.
        #expect(crlfUpdated == Self.crlf(lfUpdated))
    }

    @Test("Rewriting a config an editor keeps in CRLF does not accumulate blank lines")
    func repeatedCRLFRewritesDoNotGrowBlankLines() {
        let key = CmuxGhosttyConfigSettingEditor.sidebarFontSizeKey
        var contents = Self.crlf(Self.lfConfig)

        for value in ["11", "12", "13"] {
            contents = editor.updatedContents(contents, setting: key, value: value)
            // Model a Windows-side editor (or a CRLF-normalizing sync) that hands
            // the file back with CRLF endings before cmux writes it again.
            contents = Self.crlf(contents.replacingOccurrences(of: "\r\n", with: "\n"))
        }

        #expect(contents == Self.crlf("""
        font-family = "SF Mono"
        sidebar-font-size = 13

        """))
    }

    @Test("Appends an absent setting to a CRLF config without a leading blank line")
    func appendsAbsentSettingToCRLFConfig() {
        let updated = editor.updatedContents(
            "font-family = \"SF Mono\"\r\n",
            setting: CmuxGhosttyConfigSettingEditor.surfaceTabBarFontSizeKey,
            value: "12"
        )

        #expect(updated == "font-family = \"SF Mono\"\r\nsurface-tab-bar-font-size = 12\r\n")
    }

    @Test("Rewrites a classic-Mac CR-only config as LF, without losing its lines")
    func rewritesCROnlyConfigAsLF() {
        // A lone "\r" is read as a line break so the settings are still found and
        // replaced in place, but it is not written back: TOML — the other consumer
        // of this helper — defines a newline as LF or CRLF only, so a CR-only
        // rewrite would emit a file its own parser rejects.
        let replaced = editor.updatedContents(
            "font-family = \"SF Mono\"\rsidebar-font-size = 12\r",
            setting: CmuxGhosttyConfigSettingEditor.sidebarFontSizeKey,
            value: "13"
        )

        #expect(replaced == "font-family = \"SF Mono\"\nsidebar-font-size = 13\n")
        #expect(editor.parsedSidebarFontSize(in: replaced) == 13)

        let appended = editor.updatedContents(
            "font-family = \"SF Mono\"\r",
            setting: CmuxGhosttyConfigSettingEditor.surfaceTabBarFontSizeKey,
            value: "12"
        )

        #expect(appended == "font-family = \"SF Mono\"\nsurface-tab-bar-font-size = 12\n")
    }

    @Test("Reads back the value it wrote into a CRLF config")
    func parsesValueWrittenIntoCRLFConfig() {
        let updated = editor.updatedContents(
            Self.crlf(Self.lfConfig),
            setting: CmuxGhosttyConfigSettingEditor.sidebarFontSizeKey,
            value: "13"
        )

        #expect(editor.parsedSidebarFontSize(in: updated) == 13)
        #expect(editor.parsedValue(for: "font-family", in: updated) == "\"SF Mono\"")
    }

    @Test("Writes a setting into a CRLF config file on disk without growing it")
    func writesSettingToCRLFConfigFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-crlf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("config", isDirectory: false)
        try Self.crlf(Self.lfConfig).write(to: url, atomically: true, encoding: .utf8)

        try editor.writeSetting(
            key: CmuxGhosttyConfigSettingEditor.sidebarFontSizeKey,
            value: "13",
            to: url
        )

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written == Self.crlf("""
        font-family = "SF Mono"
        sidebar-font-size = 13

        """))
    }
}
