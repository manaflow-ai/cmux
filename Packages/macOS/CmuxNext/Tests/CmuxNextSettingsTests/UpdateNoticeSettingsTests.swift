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
}
