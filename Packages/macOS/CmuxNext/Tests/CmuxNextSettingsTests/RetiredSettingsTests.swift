import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// Retired cmux.json keys (`SettingsSchema.retiredKeys`):
/// `appearance.tabBarBackground` went away with the one background
/// (plans/cmux-next/windows.md). An old file that still sets it loads with
/// no diagnostic and no effect; Settings and the schema export never list
/// it; a write is refused as removed, not as unknown.
@Suite struct RetiredSettingsTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func tabBarBackgroundIsRetired() {
        #expect(SettingsSchema.isRetired(["appearance", "tabBarBackground"]))
        #expect(!SettingsSchema.isRetired(["appearance", "focusIndicator"]))
    }

    @Test func anOldFileLoadsWithNoDiagnosticAndNoEffect() throws {
        let old = try parse(#"{"appearance": {"tabBarBackground": "darker"}}"#)
        let fresh = try parse("{}")
        #expect(old.diagnostics.isEmpty)
        #expect(old.retiredKeys == ["appearance.tabBarBackground"])
        #expect(fresh.retiredKeys.isEmpty)
        // Every parsed setting matches a file without the key.
        var comparable = old
        comparable.root = fresh.root
        comparable.retiredKeys = []
        #expect(comparable == fresh)
    }

    @MainActor @Test func anOldFileChangesNoDesignSetting() throws {
        let fromOld = DesignSettings()
        SettingsApplier(design: fromOld, registry: ActionRegistry.standard())
            .apply(try parse(#"{"appearance": {"tabBarBackground": "darker"}}"#))
        let fromEmpty = DesignSettings()
        SettingsApplier(design: fromEmpty, registry: ActionRegistry.standard()).apply(try parse("{}"))
        #expect(fromOld.focusIndicator == fromEmpty.focusIndicator)
        #expect(fromOld.inactiveTabStyle == fromEmpty.inactiveTabStyle)
        #expect(fromOld.borders == fromEmpty.borders)
    }

    @Test func noRetiredKeyIsASettingOrInTheSchemaExport() throws {
        for key in SettingsSchema.retiredKeys.keys {
            let path = key.split(separator: ".").map(String.init)
            #expect(SettingsSchema.descriptor(for: path) == nil, "\(key)")
            #expect(!SettingsSchema.all.contains { $0.path == path }, "\(key)")
        }
        let export = try SettingsSchemaExport().json(catalog: SettingsSchemaExportTests.catalog())
        for key in SettingsSchema.retiredKeys.keys {
            #expect(!export.contains(key.split(separator: ".").last.map(String.init) ?? key), "\(key) in settings-schema.json")
        }
    }

    @MainActor @Test func aWriteIsRefusedAsRemovedAndAnUnsetCleansUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-retired-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"appearance": {"tabBarBackground": "darker"}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url)
        await #expect(throws: SettingRetired.self) {
            try await settings.setSetting(at: ["appearance", "tabBarBackground"], to: .string("darker"))
        }
        #expect(String(describing: SettingRetired(key: "appearance.tabBarBackground")).contains("was removed"))
        try await settings.setSetting(at: ["appearance", "tabBarBackground"], to: nil)
        let document = try JSONC.parse(String(contentsOf: url, encoding: .utf8))
        #expect(document.value(at: ["appearance", "tabBarBackground"]) == nil)
    }
}
