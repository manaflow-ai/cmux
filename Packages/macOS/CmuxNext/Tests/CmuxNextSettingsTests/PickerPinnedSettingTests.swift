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
}
