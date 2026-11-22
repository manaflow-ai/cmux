import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// `app.quitBehavior`: "ask" unless the file says "keep", "end-keep-layout"
/// or "end-everything"; the first release's "end" reads as
/// "end-keep-layout" and is rewritten once; a bad
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
        #expect(try parse(#"{"app": {"quitBehavior": "end-keep-layout"}}"#).quitBehavior == .endKeepLayout)
        #expect(try parse(#"{"app": {"quitBehavior": "end-everything"}}"#).quitBehavior == .endEverything)
    }

    @Test func theOldEndValueKeepsTheLayout() throws {
        let snapshot = try parse(#"{"app": {"quitBehavior": "end"}}"#)
        #expect(snapshot.quitBehavior == .endKeepLayout)
        #expect(snapshot.diagnostics.isEmpty)
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
        #expect(choices.map(\.value) == ["ask", "keep", "end-keep-layout", "end-everything"])
    }

    @MainActor @Test func rememberingAChoiceWritesTheKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-quit-setting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url)
        let descriptor = try #require(SettingsSchema.descriptor(for: QuitBehaviorSetting.configPath))
        try await settings.setSetting(descriptor, to: .string("end-everything"), by: .user)
        let written = try JSONC.parse(String(contentsOf: url, encoding: .utf8))
        #expect(written.value(at: ["app", "quitBehavior"]) == .string("end-everything"))
        #expect(try parse(String(contentsOf: url, encoding: .utf8)).quitBehavior == .endEverything)
    }

    @MainActor @Test func theOldEndValueIsRewrittenOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-quit-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{\n  // mine\n  \"app\": {\"quitBehavior\": \"end\"}\n}\n".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url)
        #expect(try await settings.migrateLegacyQuitBehavior())
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(try JSONC.parse(text).value(at: ["app", "quitBehavior"]) == .string("end-keep-layout"))
        #expect(text.contains("// mine"))
        #expect(try await !settings.migrateLegacyQuitBehavior())
    }
}
