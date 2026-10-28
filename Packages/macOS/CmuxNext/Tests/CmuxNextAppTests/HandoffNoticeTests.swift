@testable import CmuxNextApp
@testable import CmuxNextCloud
import Foundation
import Testing

/// A chat handed off to a Cloud machine is followed by the app-level waiter on the hand-off store's
/// `/wait` (``SandboxRunFollower`` with ``SandboxRunFollower/Source/handoffs(wait:)``): done and
/// failed are told once, each stop at needs-you once, a cancel and progress never.
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

    static func handoff(_ status: String, version: Int, summary: String? = nil) -> Result<String, CloudAPIError> {
        let object: [String: Any] = ["handoff": ["id": id, "sessionId": "s1", "status": status, "version": version, "summary": summary ?? NSNull()]]
        return .success(String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self))
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

    private func record() -> SandboxRunRecord {
        HandoffNotices.record(CloudHandoff(id: Self.id, sessionId: "s1", status: "running", summary: nil,
                                           createdAt: Date().timeIntervalSince1970 * 1_000, version: 1), user: "u1", host: nil)
    }

    private func settle(_ follower: SandboxRunFollower) async {
        while follower.isPolling(Self.id) { await Task.yield() }
    }

    @Test func doneIsToldOnceAndEachStopAtNeedsYouOnce() async throws {
        let store = Store()
        await store.script(Self.id, [Self.handoff("starting", version: 1), Self.handoff("running", version: 2),
                                     Self.handoff("needs-you", version: 3), Self.handoff("needs-you", version: 3),
                                     Self.handoff("running", version: 4), Self.handoff("needs-you", version: 5),
                                     Self.handoff("done", version: 6, summary: "Done — fixed the test")])
        let (follower, ends) = follower(store, defaults: try defaults())
        follower.watch(record())
        await ends.wait(for: 3)
        await settle(follower)
        #expect(ends.all.map(\.outcome) == [.needsYou, .needsYou, .succeeded])
        #expect(HandoffNotices.summary(try #require(ends.all.last).snapshot) == "Done — fixed the test")
        // Each wait passes the version the last one saw.
        #expect(await store.afters == [nil, 1, 2, 3, 3, 4, 5])
        #expect(follower.following.isEmpty)
        #expect(follower.endedRun(Self.id)?.outcome == .succeeded)
    }

    @Test func aCancelAndProgressAreNeverTold() async throws {
        let store = Store()
        await store.script(Self.id, [Self.handoff("running", version: 2), Self.handoff("running", version: 3), Self.handoff("cancelled", version: 4)])
        let (follower, ends) = follower(store, defaults: try defaults())
        follower.watch(record())
        await settle(follower)
        #expect(ends.all.isEmpty)
        #expect(follower.endedRun(Self.id)?.told == true)
    }

    @Test func failedIsTold() async throws {
        let store = Store()
        await store.script(Self.id, [Self.handoff("failed", version: 2, summary: "The build broke")])
        let (follower, ends) = follower(store, defaults: try defaults())
        follower.watch(record())
        await ends.wait(for: 1)
        #expect(ends.all.map(\.outcome) == [.failed])
    }

    @Test func aStopAtNeedsYouIsNotToldAgainAfterARelaunch() async throws {
        let store = Store()
        await store.script(Self.id, [Self.handoff("needs-you", version: 3)])
        let defaults = try defaults()
        let (first, ends) = follower(store, defaults: defaults)
        first.watch(record())
        await ends.wait(for: 1)
        first.stop()
        let (relaunched, relaunchedEnds) = follower(store, defaults: defaults)
        #expect(relaunched.knows(Self.id))
        // The relaunch's wait passes the version already told, and the same stop tells nothing.
        await store.script(Self.id, [Self.handoff("needs-you", version: 3), .failure(.http(status: 404, code: nil, message: nil))])
        await settle(relaunched)
        #expect(relaunchedEnds.all.isEmpty)
        #expect(await store.afters.last == 3)
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
                     #"{"run":{"status":"succeeded"},"receipt":{"status":"succeeded"}}"#] {
            guard case .unreadable = SandboxRunFollower.Source.readHandoff(Data(body.utf8)) else {
                Issue.record("read \(body) as an answer")
                continue
            }
        }
        guard case .progress(cursor: 7) = SandboxRunFollower.Source.readHandoff(Data(#"{"handoff":{"status":"starting","version":7}}"#.utf8)) else {
            Issue.record("starting is progress")
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
        #expect(HandoffNotices.text(waiting, chat: "  ") .title == "Cloud task")
    }

    @Test func onlyStoreIDsReachThePath() {
        #expect(CloudOwnerAPIClient.isHandoffID(Self.id))
        #expect(!CloudOwnerAPIClient.isHandoffID("ho_../../v1/cloud"))
        #expect(!CloudOwnerAPIClient.isHandoffID("ho_0123456789ABCDEF0123"))
    }
}
