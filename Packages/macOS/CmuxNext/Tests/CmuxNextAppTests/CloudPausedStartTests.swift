@testable import CmuxNextApp
import CmuxNextActions
@testable import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Testing

/// A start on a paused Cloud machine resumes it (coordinator, from Leo's NIGHTLY on production, 2026-11-05:
/// "coord-test auto-paused, and start-chat on a paused machine fails in 20 s with 'Machine coord-test didn't
/// connect' (retryable:false) instead of resuming it"). An app link's script connect skips a paused machine by
/// design (only a click starts one), so a start, which names that machine, resumes it through Resume Machine.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudPausedStartTests {
    static func session(_ status: CloudMachine.Status, _ resolver: LateReceiverResolver) -> CloudMachineSession {
        let id = "vm-paused-start-\(UUID().uuidString.prefix(8))"
        return CloudMachineSession(machine: CloudMachine(id: id, status: status, displayName: "Paused VM"),
                                   appLink: CloudLinkSession(key: CloudLinkKey(machine: id), resolver: resolver),
                                   localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
    }

    /// Resume Machine, as CloudService's resumer does: the record turns running (unless `settles`, when the
    /// platform's start ends with the machine paused again). A start's resume is a script's, never a click's.
    static func resumes(_ session: CloudMachineSession, counting resumed: CloudLinkRedialSessionTests.Dials, settles: Bool = false) {
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
        let dials = CloudLinkRedialSessionTests.Dials(), resumed = CloudLinkRedialSessionTests.Dials()
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
        let dials = CloudLinkRedialSessionTests.Dials()
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

    /// The idle auto-pause parked the machine while the app's copy still read running: a start reads the record
    /// again first, so it resumes the machine instead of dialing a parked one.
    @Test func aStartReadsAnAppLinkMachinesRecordAgainFirst() async {
        let session = Self.session(.running, LateReceiverResolver(refusing: 0, dials: CloudLinkRedialSessionTests.Dials()))
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
        let dials = CloudLinkRedialSessionTests.Dials(), resumed = CloudLinkRedialSessionTests.Dials()
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

    /// A resume the platform settles back to paused is its answer: the wait resumes once, not on every redial.
    @Test func aStartsWaitResumesAMachineOnce() async {
        let resumed = CloudLinkRedialSessionTests.Dials()
        let session = Self.session(.paused, LateReceiverResolver(refusing: 0, dials: CloudLinkRedialSessionTests.Dials()))
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
    static func session(_ machine: CloudMachine) -> CloudMachineSession {
        CloudMachineSession(machine: machine, appLink: CloudLinkSession(key: CloudLinkKey(machine: machine.id),
                                                                        resolver: LateReceiverResolver(refusing: 0, dials: CloudLinkRedialSessionTests.Dials())),
                            localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
    }

    @Test func aRowNamesItsFailureAndCreationTime() throws {
        let data = Data(#"""
        {"id":"vm_1688397baaa64707a11a","status":"failed","creator":"user_a","name":"coord-test","created_at":1793868882000,
         "error":{"code":"cloud.provider.unavailable","message":"provider call failed","at":1793868890000},"revision":"7"}
        """#.utf8)
        let machine = try #require(CloudMachine(next: try JSONDecoder().decode(JSONValue.self, from: data)))
        #expect(machine.createdAt == Date(timeIntervalSince1970: 1_793_868_882))
        let session = Self.session(machine)
        guard case .object(let row) = CloudHandlers.listedMachine(session, owner: "team") else { Issue.record("not an object"); return }
        #expect(row["error"] == .object(["code": .string("cloud.provider.unavailable"), "message": .string("provider call failed")]))
        #expect(row["created_at"] != .null)
    }

    @Test func aRowWithNoFailureSaysNull() {
        let session = Self.session(CloudMachine(id: "vm-ok", status: .running))
        guard case .object(let row) = CloudHandlers.listedMachine(session, owner: "team") else { Issue.record("not an object"); return }
        #expect(row["error"] == .null)
    }
}
