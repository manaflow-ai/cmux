import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// P-AUSTIN B7a, review 3: `SessionRegistration` sends each session's record to the home registry.
/// A `DaemonConnection` reconnects in place after the home daemon restarts, so a restart is seen
/// only as a new connection epoch; a refused record must be sent again then. A record whose timed
/// retries are spent waits for an event, and the person must see that it is not saved. A pending
/// notice is dropped once the record is recorded.
@MainActor
@Suite struct SessionRegistrationTests {
    private final class Notices {
        var shown: [String] = []
        var withdrawn: [String] = []
        var windowShows = true
    }

    private let refusal = DaemonError.command(cmd: "put-session", message: "bad request: capabilities is 600000 bytes, over 524288",
                                              code: nil)

    private func registration(_ notices: Notices, timedRetries: Int = 8) -> SessionRegistration<String> {
        SessionRegistration<String>(policy: RetryPolicy(initial: .milliseconds(250), maximum: .seconds(30), timedRetries: timedRetries),
                                    notice: {
            _, message in
            guard notices.windowShows else { return false }
            notices.shown.append(message)
            return true
        }, withdraw: { session in
            notices.withdrawn.append(session)
        })
    }

    @Test func aRefusedRecordIsSentAgainAfterTheHomeDaemonReconnects() async {
        let notices = Notices()
        let registration = registration(notices)
        let refusal = refusal
        await registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 1) { throw refusal }?.value
        #expect(notices.shown.count == 1, "the refusal is not shown")
        let unchanged = registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 1) {}
        #expect(unchanged == nil, "an unchanged refused record is sent again on the same connection")
        let reconnected = registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 2) {}
        #expect(reconnected != nil, "a refused record is not sent again after the home daemon reconnected")
        await reconnected?.value
    }

    @Test func aRecordWhoseRetriesAreSpentIsShownAsNotSaved() async {
        let notices = Notices()
        let registration = registration(notices, timedRetries: 0)
        await registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 1) {
            throw DaemonError.timedOut("put-session")
        }?.value
        #expect(notices.shown.count == 1, "a record that waits for an event after its retries is not shown")
        #expect(notices.shown.first?.contains("build-box") == true)
    }

    @Test func aPendingNoticeIsDroppedOnceTheRecordIsRecorded() async {
        let notices = Notices()
        notices.windowShows = false
        let registration = registration(notices)
        let refusal = refusal
        await registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 1) { throw refusal }?.value
        await registration.submit(session: "remote-1", record: "b", machine: "build-box", epoch: 1) {}?.value
        notices.windowShows = true
        await registration.submit(session: "remote-2", record: "c", machine: "other", epoch: 1) {}?.value
        #expect(notices.shown.isEmpty, "a stale notice shows after the machine was recorded: \(notices.shown)")
    }

    @Test func aNoticeFromBeforeTheFirstWindowShowsWhenAWindowAppears() async {
        let notices = Notices()
        notices.windowShows = false
        let registration = registration(notices)
        let refusal = refusal
        await registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 1) { throw refusal }?.value
        #expect(notices.shown.isEmpty)
        notices.windowShows = true
        registration.showPendingNotices()
        #expect(notices.shown.count == 1, "the notice from before the first window does not show when it appears")
        registration.showPendingNotices()
        #expect(notices.shown.count == 1, "the notice shows twice")
    }

    /// Review 4: the toast stays until closed, so it must be taken back when it is no longer true.
    @Test func aShownNoticeIsTakenBackWhenTheRecordIsRecordedOrTheSessionIsGone() async {
        let notices = Notices()
        let registration = registration(notices)
        let refusal = refusal
        await registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 1) { throw refusal }?.value
        await registration.submit(session: "remote-2", record: "c", machine: "other", epoch: 1) { throw refusal }?.value
        #expect(notices.shown.count == 2)
        await registration.submit(session: "remote-1", record: "b", machine: "build-box", epoch: 1) {}?.value
        #expect(notices.withdrawn == ["remote-1"], "the notice still says not saved after the record was recorded")
        registration.retain(sessions: ["remote-1"])
        #expect(notices.withdrawn == ["remote-1", "remote-2"], "the notice of a session that is gone stays")
    }

    /// Review 4: a pending notice of an older record does not show while a newer send is in flight.
    @Test func aNewSendDropsTheOlderPendingNotice() async {
        let notices = Notices()
        notices.windowShows = false
        let registration = registration(notices)
        let refusal = refusal
        await registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 1) { throw refusal }?.value
        let gate = AsyncStream<Void>.makeStream()
        let inFlight = registration.submit(session: "remote-1", record: "b", machine: "build-box", epoch: 1) {
            for await _ in gate.stream { break }
        }
        notices.windowShows = true
        registration.showPendingNotices()
        #expect(notices.shown.isEmpty, "the older record's notice shows while a newer send is in flight")
        gate.continuation.yield()
        await inFlight?.value
    }

    /// Review 4: the notice reason is localized; the raw daemon text goes only to the log.
    @Test func theNoticeShowsALocalizedReasonNotTheDaemonText() async {
        let notices = Notices()
        let registration = registration(notices)
        let refusal = refusal
        await registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 1) { throw refusal }?.value
        #expect(notices.shown.count == 1)
        #expect(notices.shown.first?.contains("bad request") == false, "the notice shows the daemon's raw text: \(notices.shown)")
    }

    /// Review 5: a notice dropped by a new send before any window showed it is still owed: the
    /// same refusal on the new send shows it.
    @Test func aRefusalDroppedBeforeItShowedShowsWhenTheResendIsRefused() async {
        let notices = Notices()
        notices.windowShows = false
        let registration = registration(notices)
        let refusal = refusal
        await registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 1) { throw refusal }?.value
        await registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 2) { throw refusal }?.value
        notices.windowShows = true
        registration.showPendingNotices()
        #expect(notices.shown.count == 1, "the refusal of the resend is not shown: \(notices.shown)")
    }

    /// Review 5: a session that leaves and comes back (SSH forget and undo, server sign-out and in)
    /// had its notice taken back; the same refusal shows again.
    @Test func aSessionThatComesBackShowsItsRefusalAgain() async {
        let notices = Notices()
        let registration = registration(notices)
        let refusal = refusal
        await registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 1) { throw refusal }?.value
        registration.retain(sessions: [])
        #expect(notices.withdrawn == ["remote-1"])
        await registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 1) { throw refusal }?.value
        #expect(notices.shown.count == 2, "the refusal of a session that came back is not shown again")
    }

    /// Review 6: dropping a pending "no answer" notice must not make a refusal the person already
    /// saw show again.
    @Test func aDroppedNoAnswerNoticeDoesNotShowASeenRefusalAgain() async {
        let notices = Notices()
        let registration = registration(notices, timedRetries: 0)
        let refusal = refusal
        await registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 1) { throw refusal }?.value
        #expect(notices.shown.count == 1)
        notices.windowShows = false
        await registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 2) {
            throw DaemonError.timedOut("put-session")
        }?.value
        await registration.submit(session: "remote-1", record: "a", machine: "build-box", epoch: 3) { throw refusal }?.value
        notices.windowShows = true
        registration.showPendingNotices()
        #expect(notices.shown.count == 1, "a refusal the person already saw shows again: \(notices.shown)")
    }
}
