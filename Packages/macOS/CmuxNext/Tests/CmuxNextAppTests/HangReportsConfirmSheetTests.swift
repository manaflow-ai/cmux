@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// The approved sheet of `cmux settings set diagnostics.hangReports true --confirm` records this
/// Mac's consent, so it shows the same privacy summary as the card: what a report holds, what it
/// never holds, the random install id and View Hang Report.
@MainActor struct HangReportsConfirmSheetTests {
    @Test func turningHangReportsOnShowsThePrivacySummary() {
        let body = UserOnlySettingConfirmation.body(key: "diagnostics.hangReports", value: .bool(true))
        #expect(body.contains(HangReportsStrings.privacySummary))
        #expect(body.contains(ConfirmationStrings.userOnlySettingBody("diagnostics.hangReports", "true")))
    }

    @Test func theCardAndTheSheetShowOneSummaryThatNamesTheInstallIDAndViewHangReport() {
        let summary = HangReportsStrings.privacySummary
        #expect(summary.contains("install ID"))
        #expect(summary.contains("View Hang Report"))
        #expect(summary.contains("never holds file names"))
    }

    @Test(arguments: [JSONValue.bool(false), .null])
    func turningThemOffOrResettingShowsNoSummary(value: JSONValue) {
        let body = UserOnlySettingConfirmation.body(key: "diagnostics.hangReports", value: value == .null ? nil : value)
        #expect(!body.contains(HangReportsStrings.privacySummary))
    }

    @Test func anotherUserOnlyKeyShowsNoSummary() {
        let body = UserOnlySettingConfirmation.body(key: "browser.omnibar.searchSuggestions", value: .bool(true))
        #expect(!body.contains(HangReportsStrings.privacySummary))
    }
}
