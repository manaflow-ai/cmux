@testable import CmuxNextApp
import CmuxNextHangReports
import CmuxNextSettings
import Foundation
import Testing

/// `diagnostics.performanceData` (p09-observability task 134) has its own consent record: the person's own write of
/// the setting records it, any other value removes it, and the approved CLI sheet shows its own summary.
@MainActor struct PerformanceDataConsentTests {
    private func defaults() -> (UserDefaults, String) {
        let suite = "cn-performance-data-consent-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite) ?? .standard, suite)
    }

    @Test func theUsersWriteRecordsItsOwnConsent() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(HangReportsController.performanceDataDecision(defaults: defaults, settingOn: true) == .confirm)
        let undo = HangReportsController.recordUserWrite(defaults: defaults, path: PerformanceDataSetting.path, value: .bool(true))
        #expect(defaults.object(forKey: HangReportsController.performanceDataConsentKey) is Date)
        #expect(defaults.object(forKey: HangReportsController.consentKey) == nil, "hang reports stay unconfirmed")
        #expect(HangReportsController.performanceDataDecision(defaults: defaults, settingOn: true) == .send)
        undo?()
        #expect(defaults.object(forKey: HangReportsController.performanceDataConsentKey) == nil, "a failed write leaves no record")

        _ = HangReportsController.recordUserWrite(defaults: defaults, path: PerformanceDataSetting.path, value: .bool(true))
        _ = HangReportsController.recordUserWrite(defaults: defaults, path: PerformanceDataSetting.path, value: .bool(false))
        #expect(defaults.object(forKey: HangReportsController.performanceDataConsentKey) == nil)
    }

    @Test func turningPerformanceDataOnShowsItsSummary() {
        let body = UserOnlySettingConfirmation.body(key: "diagnostics.performanceData", value: .bool(true))
        #expect(body.contains(HangReportsStrings.performanceDataSummary))
        #expect(!body.contains(HangReportsStrings.privacySummary))
        #expect(HangReportsStrings.performanceDataSummary.contains("never holds call stacks"))
        #expect(!UserOnlySettingConfirmation.body(key: "diagnostics.performanceData", value: .bool(false))
            .contains(HangReportsStrings.performanceDataSummary))
    }
}
