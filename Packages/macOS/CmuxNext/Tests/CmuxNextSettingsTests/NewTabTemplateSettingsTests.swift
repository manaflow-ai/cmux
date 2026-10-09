import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// `tabs.newTabTemplate` (cx-yabk): the New Tab page template. Unset is nil, so the page follows
/// the Debug Settings design; a bad value is nil with a diagnostic. The Settings window and the
/// page's template dots edit it.
@Suite struct NewTabTemplateSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func unsetIsNoTemplate() throws {
        #expect(try parse("{}").newTabTemplate == nil)
        #expect(try parse("{}").diagnostics.isEmpty)
    }

    @Test func readsEveryTemplate() throws {
        for template in NewTabTemplate.allCases {
            let snapshot = try parse(#"{"tabs": {"newTabTemplate": "\#(template.rawValue)"}}"#)
            #expect(snapshot.newTabTemplate == template)
            #expect(snapshot.diagnostics.isEmpty)
        }
    }

    @Test func aBadValueIsNoTemplateWithADiagnostic() throws {
        let snapshot = try parse(#"{"tabs": {"newTabTemplate": "spreadsheet"}}"#)
        #expect(snapshot.newTabTemplate == nil)
        #expect(snapshot.diagnostics.map(\.path) == ["tabs.newTabTemplate"])
    }

    @Test func theSchemaOffersEveryTemplateAndPagesMayWriteIt() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: NewTabTemplate.configPath))
        guard case .choice(let choices) = descriptor.kind else {
            Issue.record("tabs.newTabTemplate is not a choice")
            return
        }
        #expect(choices.map(\.value) == ["default", "composer", "threads", "console", "classic", "terminal"])
        #expect(descriptor.defaultValue == .string("default"))
        #expect(SettingWriter.caller("page").mayWrite(descriptor))
    }

    /// The dots' write goes through the one write path and lands in cmux.json.
    @MainActor @Test func aPageWriteLandsInTheFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-newtab-template-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url)
        let descriptor = try #require(SettingsSchema.descriptor(for: NewTabTemplate.configPath))
        try await settings.setSetting(descriptor, to: .string("terminal"), by: .caller("page"))
        #expect(try parse(String(contentsOf: url, encoding: .utf8)).newTabTemplate == .terminal)
    }
}
