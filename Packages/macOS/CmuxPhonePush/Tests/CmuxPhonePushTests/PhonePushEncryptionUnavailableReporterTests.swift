import Testing
@testable import CmuxPhonePush

@Suite("Phone push encryption availability")
struct PhonePushEncryptionUnavailableReporterTests {
    @Test("reports once per account until a trusted key returns")
    func reportsOncePerAccountUntilKeyReturns() {
        var reporter = PhonePushEncryptionUnavailableReporter()

        let firstAccountAReport = reporter.shouldReportUnavailable(
            for: "account-a"
        )
        #expect(firstAccountAReport)
        let repeatedAccountAReport = reporter.shouldReportUnavailable(
            for: "account-a"
        )
        #expect(!repeatedAccountAReport)
        let firstAccountBReport = reporter.shouldReportUnavailable(
            for: "account-b"
        )
        #expect(firstAccountBReport)

        reporter.noteTrustedRecipientAvailable(for: "account-a")

        let accountAReportAfterKeyReturns = reporter.shouldReportUnavailable(
            for: "account-a"
        )
        #expect(accountAReportAfterKeyReturns)
        let repeatedAccountAReportAfterKeyReturns = reporter.shouldReportUnavailable(
            for: "account-a"
        )
        #expect(!repeatedAccountAReportAfterKeyReturns)
    }
}
