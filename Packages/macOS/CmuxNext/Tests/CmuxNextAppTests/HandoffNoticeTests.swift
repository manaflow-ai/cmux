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
        guard case .going(cursor: 7, notice: nil, _) = starting else { return Issue.record("starting is progress") }
        let done = SandboxRunFollower.Source.readHandoff(Data(#"{"handoff":{"status":"done","version":8,"turn":2,"state":"open"}}"#.utf8))
        guard case .going(cursor: 8, notice: CloudTaskNotice(key: "2:done", outcome: .succeeded), _) = done else { return Issue.record("a turn's done goes on") }
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

    @Test func onlyStoreIDsReachThePath() {
        #expect(CloudOwnerAPIClient.isHandoffID(Self.id))
        #expect(!CloudOwnerAPIClient.isHandoffID("ho_../../v1/cloud"))
        #expect(!CloudOwnerAPIClient.isHandoffID("ho_0123456789ABCDEF0123"))
    }
}
