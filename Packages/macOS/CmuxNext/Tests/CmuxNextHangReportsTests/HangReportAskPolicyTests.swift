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
}
