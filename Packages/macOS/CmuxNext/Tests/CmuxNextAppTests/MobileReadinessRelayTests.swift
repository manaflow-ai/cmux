@testable import CmuxNextApp
import CmuxNextMobile
import Synchronization
import Testing

struct MobileReadinessRelayTests {
    @Test func repeatedReportsDoNotGrowTheStoredCallback() async {
        await Task.detached {
            let relay = MobileReadinessRelay()
            let reports = Atomic<Int>(0)
            let session = MobileUsableSession(connectionID: "connection", clientID: "client", streamID: "stream",
                                              transport: "local", workspaceCount: 1)
            relay.report(session) // Reports before installation remain harmless.
            relay.install { _ in reports.add(1, ordering: .relaxed) }
            for _ in 0..<50_000 { relay.report(session) }
            #expect(reports.load(ordering: .relaxed) == 50_000)
        }.value
    }

    @Test func callbackCanInstallItsReplacement() {
        let relay = MobileReadinessRelay()
        let reports = Atomic<Int>(0)
        let session = MobileUsableSession(connectionID: "connection", clientID: "client", streamID: "stream",
                                          transport: "local", workspaceCount: 1)
        relay.install { _ in
            reports.add(1, ordering: .relaxed)
            relay.install { _ in reports.add(10, ordering: .relaxed) }
        }
        relay.report(session)
        relay.report(session)
        #expect(reports.load(ordering: .relaxed) == 11)
    }
}
