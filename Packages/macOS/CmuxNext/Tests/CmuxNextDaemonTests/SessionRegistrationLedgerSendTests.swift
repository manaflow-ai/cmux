import Foundation
import Testing
@testable import CmuxNextDaemon

/// P-AUSTIN B7a, review 2: an answer applies only to the send that produced it; a store error is
/// not a deterministic refusal; a session that is gone is forgotten without showing its refusal
/// again.
@Suite struct SessionRegistrationLedgerSendTests {
    private let reason = "bad request: capabilities is 600000 bytes, over 524288"
    private var refusal: SessionRegistrationLedger<String>.Failure { .refused(reason) }

    @Test func anAnswerToAnOlderSendOfTheSameRecordIsIgnored() {
        var ledger = SessionRegistrationLedger<String>()
        let first = ledger.begin(session: "remote-1", record: "a", connection: 1)
        let second = ledger.begin(session: "remote-1", record: "b", connection: 1)
        let third = ledger.begin(session: "remote-1", record: "a", connection: 1)
        #expect(first != nil && second != nil && third != nil)
        let stale = ledger.failed(session: "remote-1", token: first ?? 0, failure: refusal)
        #expect(stale.refusal == nil, "the refusal of an older send of the same record is shown")
        ledger.succeeded(session: "remote-1", token: third ?? 0)
        #expect(ledger.isRecorded(session: "remote-1"))
        let late = ledger.failed(session: "remote-1", token: second ?? 0, failure: refusal)
        #expect(late.refusal == nil, "a late refusal of a replaced record is shown")
        #expect(ledger.isRecorded(session: "remote-1"), "a late refusal undid the recorded state")
    }

    @Test func anAnswerFromAnOldConnectionIsIgnored() {
        var ledger = SessionRegistrationLedger<String>()
        let old = ledger.begin(session: "remote-1", record: "a", connection: 1)
        let current = ledger.begin(session: "remote-1", record: "a", connection: 2)
        #expect(old != nil && current != nil && old != current)
        let stale = ledger.failed(session: "remote-1", token: old ?? 0, failure: refusal)
        #expect(stale.refusal == nil, "the old connection's refusal is shown")
        ledger.succeeded(session: "remote-1", token: current ?? 0)
        #expect(ledger.isRecorded(session: "remote-1"))
    }

    @Test func aStoreErrorBacksOffInsteadOfWaitingForARestart() {
        typealias Ledger = SessionRegistrationLedger<String>
        let store = DaemonError.command(cmd: "put-session", message: "disk I/O error", code: nil)
        #expect(Ledger.classify(store) == .unreachable, "a store error waits for a daemon restart")
        let invalid = DaemonError.command(cmd: "put-session", message: reason, code: nil)
        #expect(Ledger.classify(invalid) == .refused(reason))
    }

    @Test func aGoneSessionIsForgottenAndItsRefusalIsNotShownAgain() {
        var ledger = SessionRegistrationLedger<String>()
        let token = ledger.begin(session: "remote-1", record: "a", connection: 1)
        let refused = ledger.failed(session: "remote-1", token: token ?? 0, failure: refusal)
        #expect(refused.refusal == reason)
        ledger.retain(sessions: [])
        let again = ledger.begin(session: "remote-1", record: "a", connection: 1)
        #expect(again != nil, "a session that came back is not sent again")
        let refusedAgain = ledger.failed(session: "remote-1", token: again ?? 0, failure: refusal)
        #expect(refusedAgain.refusal == nil, "the same refusal is shown again after the session came back")
    }
}
