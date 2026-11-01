import Foundation
import Testing
@testable import CmuxNextDaemon

/// P-AUSTIN B7a: the app records each connected session in the home registry (`put-session`).
/// A refusal (the daemon refused every record over 4,096 bytes of capabilities) left the machine
/// out of the registry with no sign, so the next launch did not restore it. A refusal is now shown
/// once and the same record is not sent again until it changes or the daemon restarts (it would
/// fail again: no retry loop). A failure with no answer retries with a capped, jittered backoff,
/// then waits for an event. (`#expect` cannot take a mutating call, so each result is read first.)
@Suite struct SessionRegistrationLedgerTests {
    private final class Link {}
    private let home = Link()
    private let restarted = Link()
    private let reason = "bad request: capabilities is 600000 bytes, over 524288"
    private var refusal: DaemonError { .command(cmd: "put-session", message: reason, code: nil) }

    @Test func aRefusedRecordIsShownOnceAndNotSentAgainUntilItChanges() {
        var ledger = SessionRegistrationLedger<String>()
        let link = ObjectIdentifier(home)
        let sent = ledger.shouldSend(session: "remote-1", record: "a", connection: link)
        #expect(sent)
        let outcome = ledger.failed(session: "remote-1", record: "a", error: refusal)
        #expect(outcome.refusal == reason, "the refusal is not shown")
        #expect(outcome.retryAfter == nil, "a refusal is retried on a timer")
        #expect(!ledger.isRecorded(session: "remote-1"), "a refused record counts as recorded")
        let resent = ledger.shouldSend(session: "remote-1", record: "a", connection: link)
        #expect(!resent, "an unchanged refused record is sent again on the next sync")
        let changed = ledger.shouldSend(session: "remote-1", record: "b", connection: link)
        #expect(changed, "a changed record is not sent")
        let changedOutcome = ledger.failed(session: "remote-1", record: "b", error: refusal)
        #expect(changedOutcome.refusal != nil, "the changed record's refusal is not shown")
        let changedResent = ledger.shouldSend(session: "remote-1", record: "b", connection: link)
        #expect(!changedResent)
    }

    @Test func aRefusedRecordIsSentAgainAfterTheDaemonRestartsAndShownOnlyOnce() {
        var ledger = SessionRegistrationLedger<String>()
        let first = ledger.shouldSend(session: "remote-1", record: "a", connection: ObjectIdentifier(home))
        #expect(first)
        let refused = ledger.failed(session: "remote-1", record: "a", error: refusal)
        #expect(refused.refusal != nil)
        let afterRestart = ledger.shouldSend(session: "remote-1", record: "a", connection: ObjectIdentifier(restarted))
        #expect(afterRestart, "a restarted daemon does not get the record again")
        let again = ledger.failed(session: "remote-1", record: "a", error: refusal)
        #expect(again.refusal == nil, "the same refusal is shown twice")
    }

    @Test func noAnswerRetriesWithBackoffThenWaitsForAnEvent() {
        var ledger = SessionRegistrationLedger<String>(policy: RetryPolicy(initial: .milliseconds(250), maximum: .seconds(30),
                                                                           timedRetries: 2))
        let link = ObjectIdentifier(home)
        var send = ledger.shouldSend(session: "remote-1", record: "a", connection: link)
        #expect(send)
        let first = ledger.failed(session: "remote-1", record: "a", error: DaemonError.timedOut("put-session"))
        #expect(first.refusal == nil, "a failure with no answer is shown as a refusal")
        #expect(first.retryAfter != nil, "a failure with no answer does not back off")
        send = ledger.shouldSend(session: "remote-1", record: "a", connection: link)
        #expect(!send, "a sync during the backoff sends")
        ledger.retryDue(session: "remote-1")
        send = ledger.shouldSend(session: "remote-1", record: "a", connection: link)
        #expect(send, "the retry does not send")
        let second = ledger.failed(session: "remote-1", record: "a", error: DaemonError.notConnected)
        #expect(second.retryAfter != nil)
        ledger.retryDue(session: "remote-1")
        send = ledger.shouldSend(session: "remote-1", record: "a", connection: link)
        #expect(send)
        let third = ledger.failed(session: "remote-1", record: "a", error: DaemonError.notConnected)
        #expect(third.retryAfter == nil, "the timed retries have no end")
        send = ledger.shouldSend(session: "remote-1", record: "a", connection: link)
        #expect(!send, "a spent budget still sends on a sync")
        send = ledger.shouldSend(session: "remote-1", record: "a", connection: ObjectIdentifier(restarted))
        #expect(send, "a new connection does not send")
        ledger.succeeded(session: "remote-1", record: "a")
        #expect(ledger.isRecorded(session: "remote-1"))
    }

    @Test func aLateAnswerForAReplacedRecordChangesNothing() {
        var ledger = SessionRegistrationLedger<String>()
        let link = ObjectIdentifier(home)
        let sentA = ledger.shouldSend(session: "remote-1", record: "a", connection: link)
        #expect(sentA)
        let sentB = ledger.shouldSend(session: "remote-1", record: "b", connection: link)
        #expect(sentB)
        let late = ledger.failed(session: "remote-1", record: "a", error: refusal)
        #expect(late == .init(refusal: nil, retryAfter: nil), "the refusal of a replaced record is shown")
        ledger.succeeded(session: "remote-1", record: "b")
        #expect(ledger.isRecorded(session: "remote-1"))
        let resent = ledger.shouldSend(session: "remote-1", record: "b", connection: link)
        #expect(!resent)
    }

    @Test func onlyADaemonRefusalThatIsNotRetryableIsDeterministic() {
        typealias Ledger = SessionRegistrationLedger<String>
        #expect(Ledger.classify(refusal) == .refused(reason))
        #expect(Ledger.classify(DaemonError.command(cmd: "put-session", message: "busy", code: "server.busy", retryable: true))
            == .unreachable)
        #expect(Ledger.classify(DaemonError.timedOut("put-session")) == .unreachable)
        #expect(Ledger.classify(DaemonError.connectionClosed(reason: "eof")) == .unreachable)
        #expect(Ledger.classify(DaemonError.notConnected) == .unreachable)
    }
}
