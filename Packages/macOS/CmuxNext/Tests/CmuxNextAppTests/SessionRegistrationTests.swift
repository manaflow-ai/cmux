import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// P-AUSTIN B7a, review 3: `SessionRegistration` sends each session's record to the home registry.
/// A `DaemonConnection` reconnects in place after the home daemon restarts, so a restart is seen
/// only as a new connection epoch; a refused record must be sent again then. A refusal or a record
/// whose timed retries are spent is logged and counted, never shown: the person cannot act on it.
@MainActor
@Suite struct SessionRegistrationTests {
    private let refusal = DaemonError.command(cmd: "put-session", message: "bad request: capabilities is 600000 bytes, over 524288",
                                              code: nil)

    private func registration(timedRetries: Int = 8) -> SessionRegistration<String> {
        SessionRegistration<String>(policy: RetryPolicy(initial: .milliseconds(250), maximum: .seconds(30), timedRetries: timedRetries))
    }

    @Test func aRefusedRecordIsSentAgainAfterTheHomeDaemonReconnects() async {
        let registration = registration()
        let refusal = refusal
        await registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 1) { throw refusal }?.value
        let unchanged = registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 1) {}
        #expect(unchanged == nil, "an unchanged refused record is sent again on the same connection")
        let reconnected = registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 2) {}
        #expect(reconnected != nil, "a refused record is not sent again after the home daemon reconnected")
        await reconnected?.value
    }

    /// The "lane-... was not saved for restore" toast stacked over the composer during turns and
    /// the person could do nothing about it: the refusal is counted for diagnostics instead.
    @Test func aRefusedRecordIsCountedNotShown() async {
        let registration = registration()
        let refusal = refusal
        await registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 1) { throw refusal }?.value
        #expect(registration.refusedCount == 1)
        #expect(registration.unansweredCount == 0)
        await registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 1) { throw refusal }?.value
        #expect(registration.refusedCount == 1, "an unchanged refused record is counted again")
        await registration.submit(session: "remote-1", record: "b", machine: "build-box", epoch: 1) { throw refusal }?.value
        #expect(registration.refusedCount == 2)
    }

    @Test func aRecordWhoseRetriesAreSpentIsCountedAsUnanswered() async {
        let registration = registration(timedRetries: 0)
        await registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 1) {
            throw DaemonError.timedOut("put-session")
        }?.value
        #expect(registration.unansweredCount == 1)
        #expect(registration.refusedCount == 0)
    }

    @Test func aRecordedSessionIsNotCounted() async {
        let registration = registration()
        await registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 1) {}?.value
        #expect(registration.refusedCount == 0 && registration.unansweredCount == 0)
    }

    private struct Listed {
        let id: String
        let session: String?
        var local = false
    }

    /// Nine Cloud machines made from one image reported one registry id. Each sync put nine different
    /// records under it; each put changed the row and the personal revision the registrar watches, so it
    /// synced again at once: about 50 writes a second at idle, for good. One machine per registry id is sent:
    /// this Mac first, then the lowest machine id, whatever order the machines are listed in.
    @Test func oneMachinePerRegistryIDIsRegistered() {
        let machines = [Listed(id: "vm-c", session: "reg-1"), Listed(id: "vm-a", session: "reg-1"),
                        Listed(id: "vm-b", session: "reg-2"), Listed(id: "vm-d", session: nil),
                        Listed(id: "vm-e", session: "reg-1")]
        let picked = machines.onePerRegistryID(\.session, \.local, \.id)
        #expect(picked.map(\.id) == ["vm-a", "vm-b"], "\(picked.map(\.id))")
        let reversed = machines.reversed().onePerRegistryID(\.session, \.local, \.id)
        #expect(reversed.map(\.id).sorted() == ["vm-a", "vm-b"], "the pick follows the list order: \(reversed.map(\.id))")
        let home = (machines + [Listed(id: "local", session: "reg-1", local: true)]).onePerRegistryID(\.session, \.local, \.id)
        #expect(home.map(\.id).sorted() == ["local", "vm-b"], "this Mac does not keep its own registry id: \(home.map(\.id))")
    }
}
