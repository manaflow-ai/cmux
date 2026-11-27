@testable import CmuxNextApp
import CmuxNextActions
@testable import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// A start on a paused Cloud machine resumes it (coordinator, from Leo's NIGHTLY on production, 2026-11-05:
/// "coord-test auto-paused, and start-chat on a paused machine fails in 20 s with 'Machine coord-test didn't
/// connect' (retryable:false) instead of resuming it"). An app link's script connect skips a paused machine by
/// design (only a click starts one), so a start, which names that machine, resumes it through Resume Machine.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudPausedStartTests {
    /// Observable: the waits below re-read their condition on each change.
    @MainActor @Observable
    final class Dials {
        var refused = 0
        var answered = 0
    }

    static func session(_ status: CloudMachine.Status, _ resolver: LateReceiverResolver) -> CloudMachineSession {
        let id = "vm-paused-start-\(UUID().uuidString.prefix(8))"
        return CloudMachineSession(machine: CloudMachine(id: id, status: status, displayName: "Paused VM"),
                                   appLink: CloudLinkSession(key: CloudLinkKey(machine: id), resolver: resolver),
                                   localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
    }

    /// Resume Machine, as CloudService's resumer does: the record turns running (unless `settles`, when the
    /// platform's start ends with the machine paused again). A start's resume is a script's, never a click's.
    static func resumes(_ session: CloudMachineSession, counting resumed: CloudPausedStartTests.Dials, settles: Bool = false) {
        session.resumer = { [weak session] _, origin in
            resumed.refused += 1
            #expect(origin == .script, "a start resumed the machine as a click")
            guard let session, !settles else { return }
            var live = session.machine
            live.status = .running
            live.pauseReason = nil
            session.applyRecord(live)
        }
    }

    @Test func aScriptAttachResumesAPausedAppLinkMachineAndThenDials() async {
        let dials = CloudPausedStartTests.Dials(), resumed = CloudPausedStartTests.Dials()
        let session = Self.session(.paused, LateReceiverResolver(refusing: 0, dials: dials))
        defer { session.disconnect() }
        Self.resumes(session, counting: resumed)
        session.attach(origin: .script)
        #expect(await CloudWait.holds(within: .seconds(10)) { dials.answered > 0 }, "a paused machine was never resumed and dialed")
        #expect(resumed.refused == 1)
    }

    /// `cloud start-chat` runs as the person's start (agents' starts are delegated by default), so its attach is a
    /// `user` one. On a paused app-link machine that attach went straight to a connect, which the platform refuses
    /// (`cloud.machine.paused`: no automatic start), and the start failed at once with "didn't connect" (prod,
    /// 2026-11-05, on the DEV build with #36369). It resumes through Resume Machine with the person's origin.
    @Test func aPersonsAttachResumesAPausedAppLinkMachineAndThenDials() async {
        let dials = CloudPausedStartTests.Dials()
        let session = Self.session(.paused, LateReceiverResolver(refusing: 0, dials: dials))
        defer { session.disconnect() }
        var origins: [CloudLinkOrigin] = []
        session.resumer = { [weak session] _, origin in
            origins.append(origin)
            guard let session else { return }
            var live = session.machine
            live.status = .running
            live.pauseReason = nil
            session.applyRecord(live)
        }
        session.attach(origin: .user)
        #expect(await CloudWait.holds(within: .seconds(10)) { dials.answered > 0 }, "the resumed machine was never dialed")
        #expect(origins == [.user], "a person's attach on a paused machine never resumed it through Resume Machine")
        #expect(session.resumeFailure == nil)
    }

    /// Retry and Reconnect (the progress view's Retry, a machine header's Reconnect, a creation's Retry) resume a
    /// paused app-link machine as an attach does: they connected straight away, which the platform refuses.
    @Test func retryResumesAPausedAppLinkMachineAndThenDials() async {
        let dials = CloudPausedStartTests.Dials()
        let session = Self.session(.paused, LateReceiverResolver(refusing: 0, dials: dials))
        defer { session.disconnect() }
        var origins: [CloudLinkOrigin] = []
        session.resumer = { [weak session] _, origin in
            origins.append(origin)
            guard let session else { return }
            var live = session.machine
            live.status = .running
            live.pauseReason = nil
            session.applyRecord(live)
        }
        session.retry()
        #expect(await CloudWait.holds(within: .seconds(10)) { dials.answered > 0 }, "the resumed machine was never dialed")
        #expect(origins == [.user], "Retry on a paused machine never resumed it through Resume Machine")
        #expect(session.resumeFailure == nil)
    }

    /// The idle auto-pause parked the machine while the app's copy still read running: a start reads the record
    /// again first, so it resumes the machine instead of dialing a parked one.
    @Test func aStartReadsAnAppLinkMachinesRecordAgainFirst() async {
        let session = Self.session(.running, LateReceiverResolver(refusing: 0, dials: CloudPausedStartTests.Dials()))
        defer { session.disconnect() }
        var reads = 0
        session.refresher = { [weak session] _ in
            reads += 1
            guard let session else { return }
            var parked = session.machine
            parked.status = .paused
            parked.pauseReason = .idle
            session.applyRecord(parked)
        }
        await session.refreshIfMaybePaused()
        #expect(reads == 1)
        #expect(session.machine.status == .paused)
    }

    /// The record read running, the dial found the machine parked (its end's list read says paused): the start's
    /// wait resumes it and dials again, instead of ending on "didn't connect".
    @Test func aStartsWaitResumesAMachineThatTurnsOutPausedOnConnect() async {
        let dials = CloudPausedStartTests.Dials(), resumed = CloudPausedStartTests.Dials()
        let session = Self.session(.running, LateReceiverResolver(refusing: 1, dials: dials))
        defer { session.disconnect() }
        var parkedOnce = false
        session.refresher = { [weak session] _ in
            guard let session, !parkedOnce else { return }
            parkedOnce = true
            var parked = session.machine
            parked.status = .paused
            parked.pauseReason = .idle
            session.applyRecord(parked)
        }
        Self.resumes(session, counting: resumed)
        session.connect()
        let wait = Task { await session.linkUp(within: .seconds(8)) }
        #expect(await CloudWait.holds(within: .seconds(10)) { dials.answered > 0 }, "the parked machine was never resumed and dialed again")
        #expect(resumed.refused == 1)
        #expect(session.resumeFailure == nil)
        wait.cancel()
        _ = await wait.value
    }

    /// Retry on a machine the app's record still reads running while the idle auto-pause parked it: it reads the record
    /// first and resumes the machine, instead of a connect the platform refuses (review of #36760, F2).
    @Test func retryReadsAStaleRunningRecordAndResumesTheParkedMachine() async {
        let dials = CloudPausedStartTests.Dials()
        let session = Self.session(.running, LateReceiverResolver(refusing: 0, dials: dials))
        defer { session.disconnect() }
        var reads = 0, origins: [CloudLinkOrigin] = []
        session.refresher = { [weak session] _ in
            reads += 1
            guard let session, reads == 1 else { return }
            var parked = session.machine
            parked.status = .paused
            parked.pauseReason = .idle
            session.applyRecord(parked)
        }
        session.resumer = { [weak session] _, origin in
            origins.append(origin)
            guard let session else { return }
            var live = session.machine
            live.status = .running
            live.pauseReason = nil
            session.applyRecord(live)
        }
        session.retry()
        #expect(await CloudWait.holds(within: .seconds(10)) { dials.answered > 0 }, "the parked machine was never resumed and dialed")
        #expect(reads >= 1, "Retry never read the record")
        #expect(origins == [.user], "Retry dialed a parked machine instead of resuming it")
    }

    /// A resume that failed ends the link wait (``CloudMachineSession/linkUp(within:)``) but is no link that came
    /// back (review of #36760, F1): a start's EOF retry and its final check read ``CloudMachineSession/linkHeld()``.
    @Test func aFailedResumeIsNoLinkThatHolds() async {
        let session = Self.session(.paused, LateReceiverResolver(refusing: 0, dials: CloudPausedStartTests.Dials()))
        defer { session.disconnect() }
        session.resumer = { _, _ in throw URLError(.badServerResponse) }
        session.attach(origin: .script)
        #expect(await session.linkUp(within: .seconds(4)), "the failed resume did not end the wait")
        #expect(session.resumeFailure != nil)
        #expect(!session.linkHeld())
    }

    /// A resume the platform settles back to paused is its answer: the wait resumes once, not on every redial.
    @Test func aStartsWaitResumesAMachineOnce() async {
        let resumed = CloudPausedStartTests.Dials()
        let session = Self.session(.paused, LateReceiverResolver(refusing: 0, dials: CloudPausedStartTests.Dials()))
        defer { session.disconnect() }
        Self.resumes(session, counting: resumed, settles: true)
        #expect(await session.linkUp(within: .seconds(4)) == false)
        #expect(resumed.refused == 1)
    }
}

/// `cmux cloud list-machines --json` rows carry the record's failure and its creation time: on Leo's NIGHTLY six
/// failed machines listed no reason and every row's created_at was null.
@MainActor @Suite
struct CloudListedMachineRowTests {
    @Test func aRowNamesItsFailureAndCreationTime() throws {
        let data = Data(#"""
        {"id":"vm_1688397baaa64707a11a","status":"failed","creator":"user_a","name":"coord-test","created_at":1793868882000,
         "error":{"code":"cloud.provider.unavailable","message":"provider call failed","at":1793868890000},"revision":"7"}
        """#.utf8)
        let machine = try #require(CloudMachine(next: try JSONDecoder().decode(JSONValue.self, from: data)))
        #expect(machine.createdAt == Date(timeIntervalSince1970: 1_793_868_882))
    }
}

/// A Cloud machine whose receiver is not up for its first `refusing` dials: those end as a dropped link does
/// (`disconnected`), and later dials answer a socket.
actor LateReceiverResolver: CloudLinkResolver {
    private var refusing: Int
    private let dials: CloudPausedStartTests.Dials
    private let refusal: CloudLinkError

    init(refusing: Int, dials: CloudPausedStartTests.Dials, refusal: CloudLinkError = .disconnected(reason: "receiver not up")) {
        self.refusing = refusing
        self.dials = dials
        self.refusal = refusal
    }

    func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
        let dials = dials
        if refusing > 0 {
            refusing -= 1
            await MainActor.run { dials.refused += 1 }
            throw refusal
        }
        await MainActor.run { dials.answered += 1 }
        return CloudLinkSocket(key: key, path: "/tmp/cn-redial-\(key.machine).sock", generation: 1)
    }

    func close(_ key: CloudLinkKey) async {}
}
