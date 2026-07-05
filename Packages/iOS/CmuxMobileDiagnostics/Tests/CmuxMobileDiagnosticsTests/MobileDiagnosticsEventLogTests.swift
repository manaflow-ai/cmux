import Foundation
import Testing
@testable import CmuxMobileDiagnostics

@Suite struct MobileDiagnosticsEventLogTests {
    @Test func snapshotPreservesOrderAndEvictsOldest() async {
        let base = Date(timeIntervalSince1970: 1_000)
        let log = MobileDiagnosticsEventLog(capacity: 2, now: { base })

        await log.record("auth.signedIn")
        await log.record("conn.state", fields: ["to": "connected"])
        await log.record("conn.error", fields: ["message": "token=secret"])

        let events = await log.snapshot()
        #expect(events.count == 2)
        #expect(events[0].name == "conn.state")
        #expect(events[1].name == "conn.error")
        #expect(events[1].fields["message"] == "token=<redacted>")
    }
}
