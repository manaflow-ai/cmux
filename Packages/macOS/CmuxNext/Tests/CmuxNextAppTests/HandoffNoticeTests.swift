import AppKit
@testable import CmuxNextApp
@testable import CmuxNextCloud
import Foundation
import Testing

/// A chat handed off to a Cloud machine is followed by the app-level waiter on the hand-off store's
/// `/wait` (``SandboxRunFollower`` with ``SandboxRunFollower/Source/handoffs(wait:)``). A hand-off
/// lasts the whole session and counts turns: each turn's done, failed and needs-you is told once
/// (per id, turn and status), a cancel and progress never, and the follow stops only when it closes.
@Suite(.serialized)
@MainActor
struct HandoffNoticeTests {
    /// The store's `/wait`, scripted per hand-off: each call takes the next answer, the last repeats.
    actor Store {
        var answers: [String: [Result<String, CloudAPIError>]] = [:]
        private(set) var afters: [Int?] = []

        func script(_ id: String, _ answers: [Result<String, CloudAPIError>]) { self.answers[id] = answers }

        func wait(_ id: String, after: Int?) throws -> Data {
            afters.append(after)
            guard var queue = answers[id], let first = queue.first else { throw CloudAPIError.http(status: 404, code: nil, message: nil) }
            if queue.count > 1 { queue.removeFirst(); answers[id] = queue }
            return Data(try first.get().utf8)
        }
    }

    static let id = "ho_0123456789abcdef0123"

    /// A `{handoff}` answer; `turn` and `state` nil leave them out (the store before turns).
    static func handoff(_ status: String, version: Int, turn: Int? = 1, state: String? = "open", summary: String? = nil) -> Result<String, CloudAPIError> {
        var handoff: [String: Any] = ["id": id, "sessionId": "s1", "status": status, "version": version, "summary": summary ?? NSNull()]
        if let turn { handoff["turn"] = turn }
        if let state { handoff["state"] = state }
        return .success(String(decoding: (try? JSONSerialization.data(withJSONObject: ["handoff": handoff])) ?? Data(), as: UTF8.self))
    }

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "HandoffNoticeTests.\(UUID().uuidString)"))
    }

    private func follower(_ store: Store, defaults: UserDefaults) -> (SandboxRunFollower, SandboxRunNoticeTests.Ends) {
        let follower = SandboxRunFollower(source: .handoffs(wait: { id, after in try await store.wait(id, after: after) }),
                                          defaults: defaults, clock: ImmediateRunClock())
        let ends = SandboxRunNoticeTests.Ends()
        follower.onEnd = { ends.add($0) }
        follower.account("u1")
        return (follower, ends)
    }

    private static func listEntry(status: String = "starting", version: Int? = nil, turn: Int? = nil) -> CloudHandoff {
        CloudHandoff(id: id, sessionId: "s1", status: status, summary: nil, createdAt: Date().timeIntervalSince1970 * 1_000,
                     version: version, turn: turn, state: "open")
    }

    private func record() -> SandboxRunRecord { HandoffNotices.record(Self.listEntry(), user: "u1", host: nil) }

    private func settle(_ follower: SandboxRunFollower) async {
        while follower.isPolling(Self.id) { await Task.yield() }
    }

    @Test func eachTurnsDoneAndNeedsYouAreToldOnceAndTheFollowOutlivesATurn() async throws {
        let store = Store()
        await store.script(Self.id, [
            Self.handoff("starting", version: 1), Self.handoff("running", version: 2),
            Self.handoff("needs-you", version: 3), Self.handoff("needs-you", version: 3),
            Self.handoff("running", version: 4),
            // The same turn stops for the person again: (turn 1, needs-you) was told.
            Self.handoff("needs-you", version: 5),
            Self.handoff("done", version: 6, summary: "Fixed the test"),
            // A follow-up in the same chat: turn 2 on the same id, whose done is told too.
            Self.handoff("running", version: 7, turn: 2), Self.handoff("done", version: 8, turn: 2, summary: "Pushed"),
            Self.handoff("done", version: 9, turn: 2, state: "closed", summary: "Pushed"),
        ])
        let (follower, ends) = follower(store, defaults: try defaults())
        follower.watch(record())
        await settle(follower)
        #expect(ends.all.map(\.outcome) == [.needsYou, .succeeded, .succeeded])
        #expect(ends.all.map { HandoffNotices.summary($0.snapshot) } == [nil, "Fixed the test", "Pushed"])
        // Each wait passes the version the last one saw.
        #expect(await store.afters == [nil, 1, 2, 3, 3, 4, 5, 6, 7, 8])
        // Closed: no more waits, and nothing is told for the close itself.
        #expect(follower.following.isEmpty)
        #expect(follower.endedRun(Self.id)?.told == true)
    }

    @Test func aCancelAndProgressAreNeverTold() async throws {
        let store = Store()
        await store.script(Self.id, [Self.handoff("running", version: 2), Self.handoff("cancelled", version: 3),
                                     Self.handoff("running", version: 4, turn: 2),
                                     Self.handoff("cancelled", version: 5, turn: 2, state: "closed")])
        let (follower, ends) = follower(store, defaults: try defaults())
        follower.watch(record())
        await settle(follower)
        #expect(ends.all.isEmpty)
        #expect(await store.afters.count == 4)
    }

    @Test func aFailedTurnIsToldOnceAndAClosingTurnEndNotYetToldIsTold() async throws {
        let store = Store()
        await store.script(Self.id, [Self.handoff("failed", version: 2, summary: "The build broke"),
                                     Self.handoff("failed", version: 3, state: "closed"),
                                     ])
        let (follower, ends) = follower(store, defaults: try defaults())
        follower.watch(record())
        await settle(follower)
        #expect(ends.all.map(\.outcome) == [.failed])
        let store2 = Store()
        await store2.script(Self.id, [Self.handoff("done", version: 2, turn: 3, state: "closed")])
        let (closing, closingEnds) = self.follower(store2, defaults: try defaults())
        closing.watch(record())
        await settle(closing)
        #expect(closingEnds.all.map(\.outcome) == [.succeeded])
    }

    @Test func aStoreBeforeTurnsClosesAtTheFirstEnd() async throws {
        let store = Store()
        await store.script(Self.id, [Self.handoff("running", version: 2, turn: nil, state: nil),
                                     Self.handoff("done", version: 3, turn: nil, state: nil)])
        let (follower, ends) = follower(store, defaults: try defaults())
        follower.watch(record())
        await settle(follower)
        #expect(ends.all.map(\.outcome) == [.succeeded])
        #expect(await store.afters.count == 2)
    }

    @Test func aToldStopIsNotToldAgainAfterARelaunch() async throws {
        let store = Store()
        await store.script(Self.id, [Self.handoff("needs-you", version: 3)])
        let defaults = try defaults()
        let (first, ends) = follower(store, defaults: defaults)
        first.watch(record())
        await ends.wait(for: 1)
        first.stop()
        let (relaunched, relaunchedEnds) = follower(store, defaults: defaults)
        #expect(relaunched.knows(Self.id))
        // The relaunch's wait passes the version already seen, and the same stop tells nothing.
        await store.script(Self.id, [Self.handoff("needs-you", version: 3), .failure(.http(status: 404, code: nil, message: nil))])
        await settle(relaunched)
        #expect(relaunchedEnds.all.isEmpty)
        #expect(await store.afters.suffix(2) == [3, 3])
    }

    /// Issue #31040: an incognito hand-off is never saved, so after a relaunch it comes back from the
    /// owner's list. It stays incognito there: its later banners are redacted, and its click opens nothing.
    @Test func anIncognitoHandoffFoundInTheListAfterARelaunchStaysIncognito() async throws {
        let store = Store()
        await store.script(Self.id, [Self.handoff("running", version: 2)])
        let defaults = try defaults()
        let (first, _) = follower(store, defaults: defaults)
        var incognito = record()
        incognito.incognito = true
        first.watch(incognito)
        while await store.afters.isEmpty { await Task.yield() }
        first.stop()
        let (relaunched, ends) = follower(store, defaults: defaults)
        #expect(!relaunched.knows(Self.id), "an incognito hand-off's record outlived the run")
        await store.script(Self.id, [Self.handoff("needs-you", version: 3),
                                     Self.handoff("done", version: 4, state: "closed", summary: "Pushed")])
        relaunched.watch(HandoffNotices.listed(Self.listEntry(status: "running", version: 2, turn: 1), user: "u1"))
        await settle(relaunched)
        #expect(ends.all.map(\.outcome) == [.needsYou, .succeeded])
        #expect(ends.all.map(\.record.incognito) == [true, true], "a relaunch's banner of an incognito hand-off posted its full text")
        #expect(relaunched.endedRun(Self.id)?.record.incognito == true)
    }

    /// Review of #31055: the owner's list can answer before the app's own watch of an incognito hand-off;
    /// the watch's flag reaches the record already followed, which is then no longer saved.
    @Test func anIncognitoWatchAfterTheListedRecordMakesItIncognito() async throws {
        let store = Store()
        await store.script(Self.id, [Self.handoff("running", version: 2)])
        let defaults = try defaults()
        let (follower, _) = follower(store, defaults: defaults)
        follower.watch(HandoffNotices.listed(Self.listEntry(status: "running", version: 2, turn: 1), user: "u1"))
        var incognito = record()
        incognito.incognito = true
        follower.watch(incognito)
        #expect(follower.following.first?.incognito == true)
        follower.stop()
        let (relaunched, _) = self.follower(store, defaults: defaults)
        #expect(!relaunched.following.contains { $0.id == Self.id }, "an incognito hand-off's record was saved")
        relaunched.stop()
    }

    /// Review of #31055: the listed record can even end before the app's own incognito watch; the ended record
    /// is then flagged too, and no longer saved.
    @Test func anIncognitoWatchAfterTheListedRecordEndedMakesItIncognito() async throws {
        let store = Store()
        await store.script(Self.id, [Self.handoff("done", version: 3, state: "closed", summary: "Pushed")])
        let defaults = try defaults()
        let (follower, _) = follower(store, defaults: defaults)
        follower.watch(HandoffNotices.listed(Self.listEntry(status: "running", version: 2, turn: 1), user: "u1"))
        await settle(follower)
        var incognito = record()
        incognito.incognito = true
        follower.watch(incognito)
        #expect(follower.endedRun(Self.id)?.record.incognito == true)
        let (relaunched, _) = self.follower(store, defaults: defaults)
        #expect(relaunched.endedRun(Self.id) == nil, "an incognito hand-off's ended record was saved")
    }

    @Test func aHandoffFoundInTheListTellsOnlyWhatChangesAfter() async throws {
        let store = Store()
        // The store answers at its deadline with the state the list showed, then turn 3 runs and ends.
        await store.script(Self.id, [Self.handoff("done", version: 5, turn: 2), Self.handoff("running", version: 6, turn: 3),
                                     Self.handoff("done", version: 7, turn: 3), Self.handoff("done", version: 8, turn: 3, state: "closed")])
        let (follower, ends) = follower(store, defaults: try defaults())
        follower.watch(HandoffNotices.listed(Self.listEntry(status: "done", version: 5, turn: 2), user: "u1"))
        await settle(follower)
        #expect(ends.all.map(\.outcome) == [.succeeded])
        #expect(await store.afters.first == 5)
    }

    @Test func aHandoffTheStoreNoLongerShowsIsDroppedUntold() async throws {
        let store = Store()
        let (follower, ends) = follower(store, defaults: try defaults())
        follower.watch(record())
        await settle(follower)
        #expect(ends.all.isEmpty)
        #expect(!follower.knows(Self.id))
    }

    @Test func aBodyOfAnotherShapeIsUnreadable() {
        for body in [#"{}"#, #"{"handoff":{"status":"done"}}"#, #"{"handoff":{"status":"paused","version":2}}"#, "nope",
                     #"{"handoff":{"status":"done","version":2,"state":"archived"}}"#,
                     #"{"run":{"status":"succeeded"},"receipt":{"status":"succeeded"}}"#] {
            guard case .unreadable = SandboxRunFollower.Source.readHandoff(Data(body.utf8)) else {
                Issue.record("read \(body) as an answer")
                continue
            }
        }
        let starting = SandboxRunFollower.Source.readHandoff(Data(#"{"handoff":{"status":"starting","version":7,"turn":1,"state":"open"}}"#.utf8))
        guard case .going(let cursor, let notice, _, let running) = starting, cursor == 7, notice == nil, running else {
            Issue.record("starting is progress of a turn that runs")
            return
        }
        let done = SandboxRunFollower.Source.readHandoff(Data(#"{"handoff":{"status":"done","version":8,"turn":2,"state":"open"}}"#.utf8))
        guard case .going(let doneCursor, let doneNotice, _, let doneRunning) = done, doneCursor == 8, !doneRunning,
              doneNotice == CloudTaskNotice(key: "2:done", outcome: .succeeded) else {
            Issue.record("a turn's done goes on")
            return
        }
    }

    @Test func theBannerNamesTheChatThenWhatHappened() throws {
        let done = try SandboxRunEnd(record: record(), outcome: .succeeded, snapshot: Data(Self.handoff("done", version: 6, summary: "Fixed the flaky test").get().utf8))
        let named = HandoffNotices.text(done, chat: "Flaky test")
        #expect(named.title == "Flaky test")
        #expect(named.body == "Done\nFixed the flaky test")
        // No chat title: the summary's first line is the title.
        let unnamed = HandoffNotices.text(done, chat: nil)
        #expect(unnamed.title == "Fixed the flaky test")
        #expect(unnamed.body == "Done")
        let waiting = try SandboxRunEnd(record: record(), outcome: .needsYou, snapshot: Data(Self.handoff("needs-you", version: 3).get().utf8))
        #expect(HandoffNotices.text(waiting, chat: nil) == (title: "Cloud task", body: "Needs you"))
        #expect(HandoffNotices.text(waiting, chat: "  ").title == "Cloud task")
    }

    /// Milliseconds since 1970, `days` ago.
    private static func millis(daysAgo days: Double) -> Double { (Date().timeIntervalSince1970 - days * 86_400) * 1_000 }

    @Test func aSessionMadeLongAgoIsFollowedFromItsLastChangeNotItsCreation() async throws {
        // Made four days ago, last changed an hour ago: its next turn is told.
        let store = Store()
        await store.script(Self.id, [Self.handoff("done", version: 5, turn: 2), Self.handoff("running", version: 6, turn: 3),
                                     Self.handoff("done", version: 7, turn: 3), Self.handoff("done", version: 8, turn: 3, state: "closed")])
        let (follower, ends) = follower(store, defaults: try defaults())
        let recent = CloudHandoff(id: Self.id, sessionId: "s1", status: "done", summary: nil, createdAt: Self.millis(daysAgo: 4), version: nil,
                                  turn: 2, state: "open", updatedAt: Self.millis(daysAgo: 1.0 / 24))
        follower.watch(HandoffNotices.listed(recent, user: "u1"))
        await settle(follower)
        #expect(ends.all.map(\.outcome) == [.succeeded])
        // A list without its last change: counted from when the app first saw it.
        let store2 = Store()
        await store2.script(Self.id, [Self.handoff("done", version: 7, turn: 3), Self.handoff("done", version: 8, turn: 3, state: "closed")])
        let (unknown, unknownEnds) = self.follower(store2, defaults: try defaults())
        let undated = CloudHandoff(id: Self.id, sessionId: "s1", status: "running", summary: nil, createdAt: Self.millis(daysAgo: 4), version: nil,
                                   turn: 3, state: "open")
        let record = HandoffNotices.listed(undated, user: "u1")
        #expect(record.changed.map { abs($0.timeIntervalSinceNow) < 60 } == true)
        unknown.watch(record)
        await settle(unknown)
        #expect(unknownEnds.all.map(\.outcome) == [.succeeded])
        // One idle for more than three days, its turn not running, is still given up before a wait.
        let store3 = Store()
        await store3.script(Self.id, [Self.handoff("running", version: 9, turn: 4)])
        let (idle, idleEnds) = self.follower(store3, defaults: try defaults())
        let old = CloudHandoff(id: Self.id, sessionId: "s1", status: "done", summary: nil, createdAt: Self.millis(daysAgo: 5), version: nil,
                               turn: 3, state: "open", updatedAt: Self.millis(daysAgo: 4))
        idle.watch(HandoffNotices.listed(old, user: "u1"))
        await settle(idle)
        #expect(await store3.afters.isEmpty)
        #expect(idleEnds.all.isEmpty)
        #expect(!idle.knows(Self.id))
    }

    @Test func aRecordSavedLongAgoIsDatedFromTheListsLastChange() async throws {
        // Saved at an earlier launch four days ago, its turn done then; the list shows a turn begun an hour ago.
        let store = Store()
        await store.script(Self.id, [Self.handoff("running", version: 6, turn: 3), Self.handoff("done", version: 7, turn: 3),
                                     Self.handoff("done", version: 8, turn: 3, state: "closed")])
        let (follower, ends) = follower(store, defaults: try defaults())
        let saved = CloudHandoff(id: Self.id, sessionId: "s1", status: "done", summary: nil, createdAt: Self.millis(daysAgo: 5), version: nil,
                                 turn: 2, state: "open", updatedAt: Self.millis(daysAgo: 4))
        follower.watch(HandoffNotices.listed(saved, user: "u1"))
        // Before its poll first looks at its age.
        follower.refresh(Self.id, changed: Date(timeIntervalSince1970: Self.millis(daysAgo: 1.0 / 24) / 1_000), running: true)
        #expect(follower.following.first?.running == true)
        // An older date never moves it back.
        follower.refresh(Self.id, changed: Date(timeIntervalSince1970: Self.millis(daysAgo: 4) / 1_000), running: true)
        #expect(follower.following.first.flatMap(\.changed).map { $0.timeIntervalSinceNow > -7_200 } == true)
        await settle(follower)
        #expect(ends.all.map(\.outcome) == [.succeeded])
        #expect(await store.afters.count == 3)
    }

    @MainActor final class Now { var date = Date() }

    @Test func aTurnThatRunsIsNeverGivenUpForAge() async throws {
        // Each wait takes two days: the turn runs for six days without a change, then ends.
        let store = Store(), clock = Now()
        await store.script(Self.id, [Self.handoff("running", version: 2), Self.handoff("running", version: 2), Self.handoff("running", version: 2),
                                     Self.handoff("running", version: 2), Self.handoff("done", version: 3, summary: "Fixed"),
                                     Self.handoff("done", version: 4, state: "closed", summary: "Fixed")])
        let follower = SandboxRunFollower(source: .handoffs(wait: { id, after in
            await MainActor.run { clock.date = clock.date.addingTimeInterval(2 * 86_400) }
            return try await store.wait(id, after: after)
        }), defaults: try defaults(), now: { clock.date }, clock: ImmediateRunClock())
        let ends = SandboxRunNoticeTests.Ends()
        follower.onEnd = { ends.add($0) }
        follower.account("u1")
        // Listed while its turn runs, its last change four days old.
        let running = CloudHandoff(id: Self.id, sessionId: "s1", status: "running", summary: nil, createdAt: Self.millis(daysAgo: 4), version: nil,
                                   turn: 1, state: "open", updatedAt: Self.millis(daysAgo: 4))
        follower.watch(HandoffNotices.listed(running, user: "u1"))
        await settle(follower)
        #expect(ends.all.map(\.outcome) == [.succeeded])
        #expect(await store.afters == [nil, 2, 2, 2, 2, 3])
    }

    @Test func aTurnThatRunsIsGivenUpAfterThreeDaysWithoutAnAnswer() async throws {
        // The store answers nothing readable, each try two days apart: given up at the third.
        let store = Store(), clock = Now()
        await store.script(Self.id, [.failure(.http(status: 500, code: nil, message: nil))])
        let follower = SandboxRunFollower(source: .handoffs(wait: { id, after in
            await MainActor.run { clock.date = clock.date.addingTimeInterval(2 * 86_400) }
            return try await store.wait(id, after: after)
        }), defaults: try defaults(), now: { clock.date }, clock: ImmediateRunClock())
        follower.account("u1")
        follower.watch(record())
        await settle(follower)
        #expect(!follower.knows(Self.id))
        #expect(await store.afters.count == 2)
    }

    @Test func theListsTimesAreReadAsTheStoreSendsThem() throws {
        struct Page: Decodable { var handoffs: [CloudHandoff] }
        let body = #"{"handoffs":[{"id":"ho_0123456789abcdef0123","sessionId":"s1","turn":2,"state":"open","status":"running","summary":null,"#
            + #""createdAt":"2026-10-20T10:00:00.000Z","updatedAt":"2026-10-28T09:30:00.250Z"},"#
            + #"{"id":"ho_0123456789abcdef0124","sessionId":"s2","status":"done","summary":"x","createdAt":1792490400000}],"nextCursor":null}"#
        let page = try JSONDecoder().decode(Page.self, from: Data(body.utf8))
        let listed = try #require(page.handoffs.first)
        #expect(abs(listed.createdAt - 1_792_490_400_000) < 1)
        #expect(abs((listed.updatedAt ?? 0) - 1_793_179_800_250) < 1)
        #expect(listed.isRunning && listed.isOpen && listed.version == nil)
        let record = HandoffNotices.listed(listed, user: "u1")
        #expect(abs((record.changed?.timeIntervalSince1970 ?? 0) - 1_793_179_800.25) < 0.001)
        #expect(record.running == true)
        #expect(page.handoffs.last?.createdAt == 1_792_490_400_000)
        #expect(page.handoffs.last?.updatedAt == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Page.self, from: Data(#"{"handoffs":[{"id":"a","sessionId":"s","status":"done","createdAt":"yesterday"}]}"#.utf8))
        }
    }

    /// A list call held until the test answers it.
    actor HeldList {
        private var answer: CheckedContinuation<[CloudHandoff], Never>?
        private var callers: [CheckedContinuation<Void, Never>] = []
        private var calls = 0

        func list() async -> [CloudHandoff] {
            calls += 1
            for caller in callers { caller.resume() }
            callers = []
            return await withCheckedContinuation { answer = $0 }
        }

        /// Returns once the list was called.
        func called() async {
            if calls > 0 { return }
            await withCheckedContinuation { callers.append($0) }
        }

        func respond(_ handoffs: [CloudHandoff]) {
            answer?.resume(returning: handoffs)
            answer = nil
        }
    }

    @MainActor final class Account { var user: String? = "u1" }
    private static var kept: [AppServices] = []

    private func notices(_ held: HeldList, _ account: Account, store: Store) throws -> (HandoffNotices, SandboxRunFollower) {
        let (follower, _) = follower(store, defaults: try defaults())
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        Self.kept.append(services) // HandoffNotices holds its services weakly
        let notices = HandoffNotices(services: services, follower: follower, list: { await held.list() }, user: { account.user })
        return (notices, follower)
    }

    @Test func aSignOutEndsTheListCallAndItsLateAnswerFollowsNothing() async throws {
        let store = Store(), held = HeldList(), account = Account()
        await store.script(Self.id, [Self.handoff("running", version: 2)])
        let (notices, follower) = try notices(held, account, store: store)
        notices.followAccount("u1")
        await held.called()
        let call = try #require(notices.listing)
        account.user = nil
        notices.followAccount(nil)
        #expect(call.isCancelled)
        #expect(notices.listing == nil)
        await held.respond([Self.listEntry(status: "running")])
        await call.value
        #expect(!follower.knows(Self.id))
        #expect(!follower.isPolling(Self.id))
        #expect(await store.afters.isEmpty)
    }

    @Test func aListAnsweredAfterCloudWentOffOrAnotherUserSignedInFollowsNothing() async throws {
        for later in [nil, "u2"] as [String?] {
            let store = Store(), held = HeldList(), account = Account()
            await store.script(Self.id, [Self.handoff("running", version: 2)])
            let (notices, follower) = try notices(held, account, store: store)
            notices.followAccount("u1")
            await held.called()
            let call = try #require(notices.listing)
            // The account changed, and its observer has not run yet.
            account.user = later
            await held.respond([Self.listEntry(status: "running")])
            await call.value
            #expect(!follower.knows(Self.id), "user \(later ?? "none")")
            #expect(await store.afters.isEmpty)
            notices.stop()
        }
    }

    @Test func aListAnsweredForTheSameUserIsFollowed() async throws {
        let store = Store(), held = HeldList(), account = Account()
        await store.script(Self.id, [Self.handoff("running", version: 2), .failure(.http(status: 404, code: nil, message: nil))])
        let (notices, follower) = try notices(held, account, store: store)
        notices.followAccount("u1")
        await held.called()
        let call = try #require(notices.listing)
        await held.respond([Self.listEntry(status: "running")])
        await call.value
        await settle(follower)
        #expect(await store.afters == [nil, 2])
        notices.stop()
    }

    @Test func aFollowerWithNoUserWatchesNothing() async throws {
        let store = Store()
        await store.script(Self.id, [Self.handoff("running", version: 2)])
        let follower = SandboxRunFollower(source: .handoffs(wait: { id, after in try await store.wait(id, after: after) }),
                                          defaults: try defaults(), clock: ImmediateRunClock())
        // Not signed in yet (the session still loading).
        follower.watch(record())
        #expect(!follower.knows(Self.id) && !follower.isPolling(Self.id))
        // Signed out.
        follower.account("u1")
        follower.account(nil)
        follower.watch(record())
        #expect(!follower.knows(Self.id) && !follower.isPolling(Self.id))
        #expect(await store.afters.isEmpty)
    }

    @Test func onlyStoreIDsReachThePath() {
        #expect(CloudOwnerAPIClient.isHandoffID(Self.id))
        #expect(!CloudOwnerAPIClient.isHandoffID("ho_../../v1/cloud"))
        #expect(!CloudOwnerAPIClient.isHandoffID("ho_0123456789ABCDEF0123"))
    }
}
