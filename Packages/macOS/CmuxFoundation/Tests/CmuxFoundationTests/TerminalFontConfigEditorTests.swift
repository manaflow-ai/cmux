import CmuxFoundation
import Foundation
import Testing

@Suite
struct TerminalFontConfigEditorTests {
    @Test func editorParsesTerminalFontFamilyAndSize() {
        let contents = """
        font-family = Menlo
        font-size = 13
        font-family = SF Mono
        """

        let editor = CmuxGhosttyConfigSettingEditor()

        #expect(editor.parsedTerminalFontFamily(in: contents) == "SF Mono")
        #expect(editor.parsedTerminalFontSize(in: contents) == 13)
    }

    @Test func editorClampsTerminalFontSizeForSettingsControls() {
        let editor = CmuxGhosttyConfigSettingEditor()

        #expect(editor.clampedTerminalFontSize(1) == CmuxGhosttyConfigSettingEditor.minTerminalFontSize)
        #expect(editor.clampedTerminalFontSize(1000) == CmuxGhosttyConfigSettingEditor.maxTerminalFontSize)
        #expect(editor.clampedTerminalFontSize(.nan) == CmuxGhosttyConfigSettingEditor.defaultTerminalFontSize)
    }

    @Test func editorWriteSettingRoundTripsTerminalFontControls() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-terminal-font-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("config.ghostty")
        try """
        font-family = Menlo
        font-size = 12
        """.write(to: url, atomically: true, encoding: .utf8)

        let editor = CmuxGhosttyConfigSettingEditor()
        try editor.writeSetting(
            key: CmuxGhosttyConfigSettingEditor.terminalFontFamilyKey,
            value: "SF Mono",
            to: url
        )
        try editor.writeSetting(
            key: CmuxGhosttyConfigSettingEditor.terminalFontSizeKey,
            value: "14.5",
            to: url
        )

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(editor.parsedTerminalFontFamily(in: contents) == "SF Mono")
        #expect(editor.parsedTerminalFontSize(in: contents) == 14.5)
    }

    @Test func editorUpdatesOnlyPrimaryTerminalFontFamilyEntry() {
        let contents = """
        font-family = JetBrains Mono
        font-family = LXGW WenKai Mono TC
        font-size = 12
        """

        let updated = CmuxGhosttyConfigSettingEditor()
            .updatedTerminalFontFamilyContents(contents, value: "SF Mono")

        #expect(updated == "font-family = SF Mono\nfont-family = LXGW WenKai Mono TC\nfont-size = 12\n")
    }
}
