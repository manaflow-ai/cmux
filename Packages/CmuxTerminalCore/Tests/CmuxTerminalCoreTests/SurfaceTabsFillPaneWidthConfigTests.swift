import Foundation
import Testing
import CmuxFoundation
import CmuxTerminalCore

@Suite
struct SurfaceTabsFillPaneWidthConfigTests {
    @Test func defaultsToDisabled() {
        let config = GhosttyConfig()

        #expect(config.surfaceTabsFillPaneWidth == false)
        #expect(config.surfaceTabsFillPaneWidth == CmuxGhosttyConfigSettingEditor.defaultSurfaceTabsFillPaneWidth)
    }

    @Test func parsesTrueValue() {
        var config = GhosttyConfig()

        config.parse("surface-tabs-fill-pane-width = true")

        #expect(config.surfaceTabsFillPaneWidth == true)
    }

    @Test func parsesFalseValue() {
        var config = GhosttyConfig()

        config.parse("surface-tabs-fill-pane-width = true")
        config.parse("surface-tabs-fill-pane-width = false")

        #expect(config.surfaceTabsFillPaneWidth == false)
    }

    @Test(arguments: ["1", "yes", "on", "TRUE", "On"])
    func parsesAlternateTruthyForms(_ raw: String) {
        var config = GhosttyConfig()

        config.parse("surface-tabs-fill-pane-width = \(raw)")

        #expect(config.surfaceTabsFillPaneWidth == true)
    }

    @Test(arguments: ["0", "no", "off", "FALSE", "Off"])
    func parsesAlternateFalsyForms(_ raw: String) {
        var config = GhosttyConfig()

        config.parse("surface-tabs-fill-pane-width = true")
        config.parse("surface-tabs-fill-pane-width = \(raw)")

        #expect(config.surfaceTabsFillPaneWidth == false)
    }

    @Test func ignoresUnparseableValue() {
        var config = GhosttyConfig()

        config.parse("surface-tabs-fill-pane-width = true")
        config.parse("surface-tabs-fill-pane-width = maybe")

        #expect(config.surfaceTabsFillPaneWidth == true)
    }

    @Test func loadUsesParsedFlagFromInjectedLoader() {
        let loaded = GhosttyConfig.load(
            preferredColorScheme: .dark,
            useCache: false,
            loadFromDisk: { _ in
                var config = GhosttyConfig()
                config.parse("surface-tabs-fill-pane-width = true")
                return config
            }
        )

        #expect(loaded.surfaceTabsFillPaneWidth == true)
    }

    @Test func editorParsesLastFillValue() {
        let contents = """
        surface-tabs-fill-pane-width = false
        surface-tabs-fill-pane-width = true
        """

        #expect(CmuxGhosttyConfigSettingEditor.parsedSurfaceTabsFillPaneWidth(in: contents) == true)
    }

    @Test func editorReturnsNilWhenFillValueAbsent() {
        #expect(CmuxGhosttyConfigSettingEditor.parsedSurfaceTabsFillPaneWidth(in: "sidebar-font-size = 14") == nil)
    }

    @Test func editorFormatsBool() {
        #expect(CmuxGhosttyConfigSettingEditor.formattedBool(true) == "true")
        #expect(CmuxGhosttyConfigSettingEditor.formattedBool(false) == "false")
    }

    @Test func editorWriteSettingRoundTripsFillValue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tabs-fill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.ghostty")
        try "font-size = 13\n".write(to: url, atomically: true, encoding: .utf8)

        try CmuxGhosttyConfigSettingEditor.writeSetting(
            key: CmuxGhosttyConfigSettingEditor.surfaceTabsFillPaneWidthKey,
            value: CmuxGhosttyConfigSettingEditor.formattedBool(true),
            to: url
        )

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("surface-tabs-fill-pane-width = true"))
        #expect(contents.contains("font-size = 13"))
        #expect(CmuxGhosttyConfigSettingEditor.parsedSurfaceTabsFillPaneWidth(in: contents) == true)
    }
}
