import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// `app.quitBehavior`: "ask" unless the file says "keep" or "end"; a bad
/// value keeps "ask" with a diagnostic. The quit sheet's "Don't ask again"
/// writes it through the schema, and the Settings window edits it.
@Suite struct QuitBehaviorSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToAsk() throws {
        #expect(try parse("{}").quitBehavior == .ask)
        #expect(try parse("{}").diagnostics.isEmpty)
    }

    @Test func readsEveryChoice() throws {
        #expect(try parse(#"{"app": {"quitBehavior": "ask"}}"#).quitBehavior == .ask)
        #expect(try parse(#"{"app": {"quitBehavior": "keep"}}"#).quitBehavior == .keep)
        #expect(try parse(#"{"app": {"quitBehavior": "end"}}"#).quitBehavior == .end)
    }

    @Test func badValuesKeepAskWithADiagnostic() throws {
        let snapshot = try parse(#"{"app": {"quitBehavior": "kill"}}"#)
        #expect(snapshot.quitBehavior == .ask)
        #expect(snapshot.diagnostics.map(\.path) == ["app.quitBehavior"])
    }

    @Test func theSettingsWindowListsItWithEveryChoice() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: QuitBehaviorSetting.configPath))
        #expect(descriptor.section == .general)
        #expect(descriptor.defaultValue == .string("ask"))
        guard case .choice(let choices) = descriptor.kind else { Issue.record("expected a choice"); return }
        #expect(choices.map(\.value) == ["ask", "keep", "end"])
    }

    @MainActor @Test func rememberingAChoiceWritesTheKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-quit-setting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url)
        let descriptor = try #require(SettingsSchema.descriptor(for: QuitBehaviorSetting.configPath))
        try await settings.setSetting(descriptor, to: .string("end"))
        let written = try JSONC.parse(String(contentsOf: url, encoding: .utf8))
        #expect(written.value(at: ["app", "quitBehavior"]) == .string("end"))
        #expect(try parse(String(contentsOf: url, encoding: .utf8)).quitBehavior == .end)
    }
}
