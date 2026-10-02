import CmuxNextSettings
import Foundation
import Testing

/// `history.commandRetentionDays`: how long each daemon keeps recorded
/// terminal commands (user decision 2026-10-01: 30 days, real delete).
@Suite struct CommandRetentionSettingTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToThirtyDays() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.commandRetentionDays == 30)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func readsAWholeNumberOfDays() throws {
        #expect(try parse(#"{"history": {"commandRetentionDays": 7}}"#).commandRetentionDays == 7)
        #expect(try parse(#"{"history": {"commandRetentionDays": 3650}}"#).commandRetentionDays == 3650)
    }

    @Test func badValuesKeepTheDefaultWithADiagnostic() throws {
        for value in ["0", "3651", "1.5", #""30""#, "-1"] {
            let snapshot = try parse(#"{"history": {"commandRetentionDays": \#(value)}}"#)
            #expect(snapshot.commandRetentionDays == 30, "\(value)")
            #expect(snapshot.diagnostics.map(\.path) == ["history.commandRetentionDays"], "\(value)")
        }
    }

    @Test func theSettingsWindowListsItInHistory() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: CommandRetentionSetting.configPath))
        #expect(descriptor.section == .general)
        #expect(descriptor.defaultValue == .number(30))
        guard case .number(let number) = descriptor.kind else { Issue.record("expected a number"); return }
        #expect(number.range == 1...3650 && number.step == 1 && number.unit == .days)
    }
}
