@testable import CmuxNextHangReports
import Testing

/// The file alone never starts sending; a person who turned off anonymous telemetry is never
/// invited but can still confirm a switch they turned on (lead decision 2026-10-23).
struct HangReportAskPolicyTests {
    typealias Decision = HangReportAskPolicy.Decision

    @Test(arguments: [
        // settingOn, consented, invited, telemetry -> decision
        (true, true, true, true, Decision.send),
        (true, true, false, false, .send),
        (true, false, true, true, .confirm),   // a synced or agent-edited file: confirm on this Mac
        (true, false, false, false, .confirm), // telemetry off, but the person turned it on: confirm
        (false, false, false, true, .invite),
        (false, false, false, false, .off),    // telemetry off: never invited
        (false, true, false, true, .invite),
        (false, false, true, true, .off),
    ])
    func decides(settingOn: Bool, consented: Bool, invited: Bool, telemetry: Bool, expected: Decision) {
        #expect(HangReportAskPolicy().decision(settingOn: settingOn, consented: consented, invited: invited,
                                               telemetryOptIn: telemetry) == expected)
    }

    /// Performance data (task 134) needs the same per-Mac consent and never invites.
    @Test(arguments: [
        // settingOn, consented -> decision
        (false, false, Decision.off),
        (false, true, .off),
        (true, false, .confirm), // a synced or agent-edited file: confirm on this Mac
        (true, true, .send),
    ])
    func decidesPerformanceData(settingOn: Bool, consented: Bool, expected: Decision) {
        #expect(HangReportAskPolicy().performanceDataDecision(settingOn: settingOn, consented: consented) == expected)
    }

    /// Full hang reports win where the build sends them; a Release build sends the aggregates at most.
    @Test(arguments: [
        // hang reports, performance data, full reports -> mode
        (Decision.send, Decision.send, true, HangReportService.Mode.full),
        (.send, .off, true, .full),
        (.confirm, .send, true, .aggregates),
        (.invite, .off, true, .off),
        (.send, .send, false, .aggregates),
        (.send, .confirm, false, .off),
        (.off, .off, false, .off),
    ])
    func choosesTheMode(hangReports: Decision, performanceData: Decision, fullReports: Bool, expected: HangReportService.Mode) {
        #expect(HangReportAskPolicy().mode(hangReports: hangReports, performanceData: performanceData, fullReports: fullReports) == expected)
    }

    /// A confirm of what the person turned on comes before an unprompted invitation.
    @Test func picksTheCard() {
        let policy = HangReportAskPolicy()
        #expect(policy.card(hangReports: .invite, performanceData: .confirm) == .performanceDataConfirm)
        #expect(policy.card(hangReports: .confirm, performanceData: .confirm) == .hangReportsConfirm)
        #expect(policy.card(hangReports: .invite, performanceData: .off) == .hangReportsInvite)
        #expect(policy.card(hangReports: .send, performanceData: .send) == nil)
        #expect(HangReportAskPolicy.Card.performanceDataConfirm.isPerformanceData)
    }
}
