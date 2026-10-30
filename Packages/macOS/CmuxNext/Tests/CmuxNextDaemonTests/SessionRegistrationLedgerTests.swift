import Foundation
import Testing
@testable import CmuxNextDaemon

/// P-AUSTIN B7a: the app records each connected session in the home registry (`put-session`).
/// A refusal (the daemon refused every record over 4,096 bytes of capabilities) left the machine
/// out of the registry with no sign, so the next launch did not restore it. A refusal is now shown
/// once and the same record is not sent again until it changes or the daemon restarts (it would
/// fail again: no retry loop). A failure with no answer retries with a capped, jittered backoff,
/// then waits for an event.
@Suite struct SessionRegistrationLedgerTests {
    private final class Link {}
    private let home = Link()
    private let restarted = Link()
    private let refusal = DaemonError.command(cmd: "put-session", message: "bad request: capabilities is 600000 bytes, over 524288",
                                              code: nil)

    @Test func aRefusedRecordIsShownOnceAndNotSentAgainUntilItChanges() {
        var ledger = SessionRegistrationLedger<String>()
        let link = ObjectIdentifier(home)
        #expect(ledger.shouldSend(session: "remote-1", record: "a", connection: link))
        let outcome = ledger.failed(session: "remote-1", record: "a", error: refusal)
        #expect(outcome.refusal == "bad request: capabilities is 600000 bytes, over 524288", "the refusal is not shown")
        #expect(outcome.retryAfter == nil, "a refusal is retried on a timer")
        #expect(!ledger.isRecorded(session: "remote-1"), "a refused record counts as recorded")
        #expect(!ledger.shouldSend(session: "remote-1", record: "a", connection: link),
                "an unchanged refused record is sent again on the next sync")
        #expect(ledger.shouldSend(session: "remote-1", record: "b", connection: link), "a changed record is not sent")
        #expect(ledger.failed(session: "remote-1", record: "b", error: refusal).refusal != nil,
                "the changed record's refusal is not shown")
        #expect(!ledger.shouldSend(session: "remote-1", record: "b", connection: link))
    }

    @Test func aRefusedRecordIsSentAgainAfterTheDaemonRestartsAndShownOnlyOnce() {
        var ledger = SessionRegistrationLedger<String>()
        #expect(ledger.shouldSend(session: "remote-1", record: "a", connection: ObjectIdentifier(home)))
        #expect(ledger.failed(session: "remote-1", record: "a", error: refusal).refusal != nil)
        #expect(ledger.shouldSend(session: "remote-1", record: "a", connection: ObjectIdentifier(restarted)),
                "a restarted daemon does not get the record again")
        #expect(ledger.failed(session: "remote-1", record: "a", error: refusal).refusal == nil,
                "the same refusal is shown twice")
    }

    @Test func noAnswerRetriesWithBackoffThenWaitsForAnEvent() {
        var ledger = SessionRegistrationLedger<String>(policy: RetryPolicy(initial: .milliseconds(250), maximum: .seconds(30),
                                                                           timedRetries: 2))
        let link = ObjectIdentifier(home)
        #expect(ledger.shouldSend(session: "remote-1", record: "a", connection: link))
        let first = ledger.failed(session: "remote-1", record: "a", error: DaemonError.timedOut("put-session"))
        #expect(first.refusal == nil, "a failure with no answer is shown as a refusal")
        #expect(first.retryAfter != nil, "a failure with no answer does not back off")
        #expect(!ledger.shouldSend(session: "remote-1", record: "a", connection: link), "a sync during the backoff sends")
        ledger.retryDue(session: "remote-1")
        #expect(ledger.shouldSend(session: "remote-1", record: "a", connection: link), "the retry does not send")
        #expect(ledger.failed(session: "remote-1", record: "a", error: DaemonError.notConnected).retryAfter != nil)
        ledger.retryDue(session: "remote-1")
        #expect(ledger.shouldSend(session: "remote-1", record: "a", connection: link))
        #expect(ledger.failed(session: "remote-1", record: "a", error: DaemonError.notConnected).retryAfter == nil,
                "the timed retries have no end")
        #expect(!ledger.shouldSend(session: "remote-1", record: "a", connection: link), "a spent budget still sends on a sync")
        #expect(ledger.shouldSend(session: "remote-1", record: "a", connection: ObjectIdentifier(restarted)),
                "a new connection does not send")
        ledger.succeeded(session: "remote-1", record: "a")
        #expect(ledger.isRecorded(session: "remote-1"))
    }

    @Test func aLateAnswerForAReplacedRecordChangesNothing() {
        var ledger = SessionRegistrationLedger<String>()
        let link = ObjectIdentifier(home)
        #expect(ledger.shouldSend(session: "remote-1", record: "a", connection: link))
        #expect(ledger.shouldSend(session: "remote-1", record: "b", connection: link))
        #expect(ledger.failed(session: "remote-1", record: "a", error: refusal) == .init(refusal: nil, retryAfter: nil),
                "the refusal of a replaced record is shown")
        ledger.succeeded(session: "remote-1", record: "b")
        #expect(ledger.isRecorded(session: "remote-1"))
        #expect(!ledger.shouldSend(session: "remote-1", record: "b", connection: link))
    }

    @Test func onlyADaemonRefusalThatIsNotRetryableIsDeterministic() {
        typealias Ledger = SessionRegistrationLedger<String>
        #expect(Ledger.classify(refusal) == .refused("bad request: capabilities is 600000 bytes, over 524288"))
        #expect(Ledger.classify(DaemonError.command(cmd: "put-session", message: "busy", code: "server.busy", retryable: true))
            == .unreachable)
        #expect(Ledger.classify(DaemonError.timedOut("put-session")) == .unreachable)
        #expect(Ledger.classify(DaemonError.connectionClosed(reason: "eof")) == .unreachable)
        #expect(Ledger.classify(DaemonError.notConnected) == .unreachable)
    }
}
