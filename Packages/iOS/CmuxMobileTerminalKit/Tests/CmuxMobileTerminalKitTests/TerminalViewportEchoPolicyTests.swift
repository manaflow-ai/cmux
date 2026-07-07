import Testing
@testable import CmuxMobileTerminalKit

@Suite("TerminalViewportEchoPolicy")
struct TerminalViewportEchoPolicyTests {
    private let policy = TerminalViewportEchoPolicy()

    @Test("latest identified response may update effective grid")
    func latestResponseMatchesLatestReport() {
        #expect(policy.responseMatchesLatestReport(
            latestReport: (columns: 120, rows: 40),
            reportedGrid: (columns: 120, rows: 40)
        ))
    }

    @Test("older identified response cannot update effective grid")
    func olderResponseDoesNotMatchLatestReport() {
        #expect(!policy.responseMatchesLatestReport(
            latestReport: (columns: 120, rows: 40),
            reportedGrid: (columns: 100, rows: 32)
        ))
    }

    @Test("unidentified response is accepted as current")
    func unidentifiedResponseMatchesLatestReport() {
        #expect(policy.responseMatchesLatestReport(
            latestReport: (columns: 120, rows: 40),
            reportedGrid: nil
        ))
        #expect(policy.responseMatchesLatestReport(
            latestReport: nil,
            reportedGrid: (columns: 120, rows: 40)
        ))
    }

    @Test("matching identified response clears pending echo")
    func matchingResponseClearsPendingEcho() {
        #expect(policy.responseClearsPendingEcho(
            pendingEcho: (columns: 120, rows: 40),
            reportedGrid: (columns: 120, rows: 40)
        ))
        #expect(policy.responseResetsRetryCount(
            pendingEcho: (columns: 120, rows: 40),
            reportedGrid: (columns: 120, rows: 40)
        ))
    }

    @Test("older identified response keeps pending echo")
    func olderResponseKeepsPendingEcho() {
        #expect(!policy.responseClearsPendingEcho(
            pendingEcho: (columns: 120, rows: 40),
            reportedGrid: (columns: 100, rows: 32)
        ))
        #expect(!policy.responseResetsRetryCount(
            pendingEcho: (columns: 120, rows: 40),
            reportedGrid: (columns: 100, rows: 32)
        ))
    }

    @Test("unidentified response preserves legacy clearing behavior")
    func unidentifiedResponseClearsPendingEcho() {
        #expect(policy.responseClearsPendingEcho(
            pendingEcho: (columns: 120, rows: 40),
            reportedGrid: nil
        ))
        #expect(policy.responseResetsRetryCount(
            pendingEcho: (columns: 120, rows: 40),
            reportedGrid: nil
        ))
    }

    @Test("response without pending echo resets retries only")
    func responseWithoutPendingEchoResetsRetriesOnly() {
        #expect(!policy.responseClearsPendingEcho(
            pendingEcho: nil,
            reportedGrid: (columns: 120, rows: 40)
        ))
        #expect(policy.responseResetsRetryCount(
            pendingEcho: nil,
            reportedGrid: (columns: 120, rows: 40)
        ))
    }
}
