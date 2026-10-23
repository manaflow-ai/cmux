@testable import CmuxNextHangReports
import Testing

/// The one-time question goes only to people who have not been asked, have reports off, and have
/// not turned off anonymous telemetry (lead decision 2026-10-23).
struct HangReportAskPolicyTests {
    @Test(arguments: [
        (false, false, true, true),
        (false, false, false, false),  // anonymous telemetry off: never asked
        (true, false, true, false),
        (false, true, true, false),
        (true, true, false, false),
    ])
    func asksOnlyWhenNotAskedReportsOffAndTelemetryOn(asked: Bool, on: Bool, telemetry: Bool, expected: Bool) {
        #expect(HangReportAskPolicy().shouldAsk(alreadyAsked: asked, reportsOn: on, telemetryOptIn: telemetry) == expected)
    }
}
