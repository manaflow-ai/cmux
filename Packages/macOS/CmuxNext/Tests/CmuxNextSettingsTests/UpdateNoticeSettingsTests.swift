import CmuxNextSettings
import Foundation
import Testing

/// The update card is gone (Lawrence 2026-10-05, "more minimal"): a
/// staged update is the Settings row's control. No setting may exist that
/// has no effect (coordinator 2026-10-06), so the "Show a Card" choice of
/// `updates.notify` and `updates.quietHours` are removed. An old file that
/// still sets them loads with no diagnostic.
@Suite struct UpdateNoticeSettingsTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func theSettingsPageOffersNoCardAndNoQuietHours() throws {
        #expect(SettingsSchema.descriptor(for: ["updates", "quietHours"]) == nil)
        let notify = try #require(SettingsSchema.descriptor(for: UpdatesSettings.notifyPath))
        guard case .choice(let choices) = notify.kind else {
            Issue.record("updates.notify is not a choice")
            return
        }
        #expect(choices.map(\.value) == ["badge", "silent"])
        #expect(notify.defaultValue == .string("badge"))
    }

    @Test func anOldFileWithTheCardAndQuietHoursLoadsCleanly() throws {
        let old = try parse(#"{"updates": {"notify": "card", "quietHours": {"start": "22:00", "end": "07:00"}}}"#)
        #expect(old.diagnostics.isEmpty)
        #expect(old.updates.notify.rawValue == "badge")
        #expect(old.retiredKeys == ["updates.quietHours"])
    }
    /// An MDM profile written before the card went away still sets
    /// `updates.notify = "card"`, forced or recommended: the device loads
    /// it as `badge` with no diagnostic.
    @Test(arguments: [true, false]) func anOldManagedProfileWithTheCardLoadsAsBadge(forced: Bool) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "cmux-managed-card-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        let plist: [String: Any] = forced ? ["updates.notify": "card"] : ["Recommended": ["updates.notify": "card"]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        let managed = PlistManagedPreferenceReader(url: url).read()
        let effective = EffectiveSettings.merge(file: .object([:]), managed: managed, team: .none)
        let snapshot = CmuxConfigSnapshot.parse(effective.root, validDensities: [], validMetrics: [])
        #expect(snapshot.updates.notify == .badge)
        #expect(snapshot.diagnostics.isEmpty)
        #expect(effective.diagnostics.isEmpty)
    }
}
