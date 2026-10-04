@testable import CmuxNextSettings
import Foundation
import Testing

/// `picker.pinned` (R89): the cmux picker's pinned folders, read from the
/// settings store like every picker preference.
@Suite struct PickerPinnedSettingTests {
    func snapshot(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func pinnedFoldersAreAbsoluteWithHomeExpanded() throws {
        let parsed = try snapshot(#"{"picker": {"pinned": ["/w/repo", "~/notes"]}}"#)
        #expect(parsed.pickerPinned == ["/w/repo", NSHomeDirectory() + "/notes"])
        #expect(parsed.diagnostics.isEmpty)
    }

    @Test func noKeyIsNoPinsAndABadValueSaysWhy() throws {
        #expect(try snapshot("{}").pickerPinned.isEmpty)
        let bad = try snapshot(#"{"picker": {"pinned": "/w"}}"#)
        #expect(bad.pickerPinned.isEmpty)
        #expect(bad.diagnostics.contains { $0.path == "picker.pinned" })
        let relative = try snapshot(#"{"picker": {"pinned": ["repo", "/ok"]}}"#)
        #expect(relative.pickerPinned == ["/ok"])
        #expect(relative.diagnostics.count == 1)
    }

    /// Pinned Folders is the person's choice: in v1 no agent may set or
    /// reset it, and the exported schema says so to the daemon's config
    /// actor, which refuses an agent write of a key that is not settable.
    @Test func anAgentMayNotWritePinnedFolders() throws {
        let row = try #require(SettingsSchema.descriptor(for: PickerPinnedSetting.configPath))
        #expect(row.kind == .folderList)
        #expect(SettingsSchema.agentSettable(row) == false)
        #expect(SettingsSchema.agentRefusedKeys["picker.pinned"] == .userOnly)
        #expect(!SettingsSchema.agentSettableKeys.contains("picker.pinned"))
        let json = try SettingsSchemaExport().json(catalog: SettingsSchemaExportTests.catalog())
        let rows = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let settings = try #require(rows["rows"] as? [[String: Any]])
        let exported = try #require(settings.first { $0["key"] as? String == "picker.pinned" })
        #expect(exported["agent_settable"] as? Bool == false)
        #expect(exported["agent_refusal"] as? String == "userOnly")
    }
}
