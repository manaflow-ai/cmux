import Testing
@testable import CmuxNextDaemon

/// A sidebar write whose answer is unknown is sent again (never undone); a newer write to the same thing supersedes it.
@MainActor @Suite
struct PersonalWriteLedgerTests {
    @Test func aMissedDeadlineOrALostConnectionIsUnansweredARefusalIsNot() {
        #expect(PersonalWriteLedger.isUnanswered(DaemonError.timedOut("workspace.place (no reply within 2.0 seconds)")))
        #expect(PersonalWriteLedger.isUnanswered(DaemonError.notConnected))
        #expect(PersonalWriteLedger.isUnanswered(DaemonError.connectionClosed(reason: "eof")))
        #expect(PersonalWriteLedger.isUnanswered(DaemonError.command(cmd: "workspace.place", message: "busy", code: nil, retryable: true)))
        #expect(!PersonalWriteLedger.isUnanswered(DaemonError.command(cmd: "workspace.place", message: "unknown personal group g1", code: nil)))
        #expect(!PersonalWriteLedger.isUnanswered(CancellationError()))
    }

    @Test func aNewerWriteToTheSameThingSupersedesTheOlderOne() {
        let ledger = PersonalWriteLedger()
        let a = PersonalWriteLedger.workspace(session: "s", key: "a"), b = PersonalWriteLedger.workspace(session: "s", key: "b")
        let first = ledger.claim([a, b])
        #expect(!ledger.isSuperseded(first))
        let other = ledger.claim([PersonalWriteLedger.group("g1", "name")])
        #expect(!ledger.isSuperseded(first), "a write to something else supersedes nothing")
        let second = ledger.claim([a])
        #expect(!ledger.isCurrent(first, a), "last write wins for a")
        #expect(ledger.isCurrent(first, workspace: "s", "b"), "b's move is still the first write's to send")
        #expect(!ledger.isSuperseded(first), "a move of [a, b] followed by a move of a alone still sends b")
        #expect(ledger.isCurrent(second, a))
        let third = ledger.claim([b])
        #expect(ledger.isSuperseded(first), "every key the first write set was taken by a later one")
        #expect(!ledger.isSuperseded(second))
        #expect(!ledger.isSuperseded(third))
        #expect(!ledger.isSuperseded(other))
    }
}
