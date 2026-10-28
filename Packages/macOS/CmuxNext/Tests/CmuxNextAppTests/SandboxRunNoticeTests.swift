import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// A sandboxed Run handed off from the app is followed by one app-level waiter
/// (``SandboxRunFollower``), which tells its end once, never twice, and never for the
/// person's own cancel; the banner reads the task's first line and the outcome.
@Suite(.serialized)
@MainActor
struct SandboxRunNoticeTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The Run API's `/wait`, scripted per Run: each call takes the next answer, the last repeats.
    actor Server {
        var answers: [String: [Result<String, CloudAPIError>]] = [:]
        private(set) var calls: [String] = []

        func script(_ id: String, _ answers: [Result<String, CloudAPIError>]) { self.answers[id] = answers }

        func wait(_ id: String) throws -> Data {
            calls.append(id)
            guard var queue = answers[id], let first = queue.first else { throw CloudAPIError.http(status: 404, code: nil, message: nil) }
            if queue.count > 1 { queue.removeFirst(); answers[id] = queue }
            return Data(try first.get().utf8)
        }
    }

    static let running = #"{"run":{"id":"r1","status":"running"}}"#
    static let succeeded = #"{"run":{"id":"r1","status":"succeeded"},"receipt":{"status":"succeeded","exitCode":0}}"#
    static let cancelled = #"{"run":{"id":"r1","status":"cancelled"},"receipt":{"status":"cancelled"}}"#

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "SandboxRunNoticeTests.\(UUID().uuidString)"))
    }

    private func follower(_ server: Server, defaults: UserDefaults) -> (SandboxRunFollower, Ends) {
        let follower = SandboxRunFollower(wait: { id, _ in try await server.wait(id) }, defaults: defaults, clock: ImmediateRunClock())
        let ends = Ends()
        follower.onEnd = { ends.add($0) }
        return (follower, ends)
    }

    private func record(_ id: String = "r1", user: String = "u1") -> SandboxRunRecord {
        SandboxRunRecord(id: id, task: "Fix the flaky test\nthen push", key: "key-\(id)", user: user, team: "t1", started: Date())
    }

    @MainActor final class Ends {
        private(set) var all: [SandboxRunEnd] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func add(_ end: SandboxRunEnd) {
            all.append(end)
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
        /// Returns once at least `count` ends were told.
        func wait(for count: Int) async {
            while all.count < count { await withCheckedContinuation { waiters.append($0) } }
        }
    }

    @Test func aRunThatEndsIsToldOnceAndItsSendGetsTheSnapshot() async throws {
        let server = Server()
        await server.script("r1", [.success(Self.running), .success(Self.running), .success(Self.succeeded)])
        let defaults = try defaults()
        let (follower, ends) = follower(server, defaults: defaults)
        let data = try await follower.follow(record())
        #expect(String(decoding: data, as: UTF8.self) == Self.succeeded)
        #expect(ends.all.map(\.outcome) == [.succeeded])
        #expect(ends.all.first?.record.task == "Fix the flaky test\nthen push")
        #expect(!follower.isPolling("r1"))
        #expect(follower.following.isEmpty)
        // A late follow of the same Run (a page reload) tells nothing again.
        await #expect(throws: CloudAPIError.self) { try await follower.follow(record()) }
        #expect(ends.all.count == 1)
        // Nor does a relaunch: the ended Run is no longer saved.
        let (relaunched, relaunchedEnds) = self.follower(server, defaults: defaults)
        relaunched.account("u1")
        #expect(relaunched.following.isEmpty)
        #expect(relaunchedEnds.all.isEmpty)
        #expect(await server.calls.count == 3)
    }

    @Test func twoWaitersShareOnePollAndOneNotice() async throws {
        let server = Server()
        await server.script("r1", [.success(Self.running), .success(Self.succeeded)])
        let (follower, ends) = follower(server, defaults: try defaults())
        let record = record()
        let first = Task { try await follower.follow(record) }
        let second = Task { try await follower.follow(record) }
        let answers = try await [first.value, second.value]
        #expect(answers.allSatisfy { String(decoding: $0, as: UTF8.self) == Self.succeeded })
        #expect(ends.all.count == 1)
        #expect(await server.calls.count == 2)
    }

    @Test func thePersonsOwnCancelTellsNothingButACancelElsewhereDoes() async throws {
        let server = Server()
        await server.script("r1", [.success(Self.running), .success(Self.cancelled)])
        await server.script("r2", [.success(Self.running), .success(Self.cancelled)])
        let (follower, ends) = follower(server, defaults: try defaults())
        let r1 = record("r1")
        let mine = Task { try await follower.follow(r1) }
        while !follower.isPolling("r1") { await Task.yield() }
        follower.noteCancel("r1")
        _ = try await mine.value
        #expect(ends.all.isEmpty)
        _ = try await follower.follow(record("r2"))
        #expect(ends.all.map(\.outcome) == [.cancelled])
        #expect(ends.all.map(\.record.id) == ["r2"])
    }

    @Test func aCancelNotedBeforeTheFollowStartsStillTellsNothing() async throws {
        let server = Server()
        await server.script("r1", [.success(Self.cancelled)])
        let (follower, ends) = follower(server, defaults: try defaults())
        // `runs.cancel` can win the race with the send's hand-off to the follower.
        follower.noteCancel("r1")
        _ = try await follower.follow(record("r1"))
        #expect(ends.all.isEmpty)
    }

    @Test func aBodyThatIsNoRunSnapshotIsNeverAnEnd() {
        func read(_ body: String) -> String {
            switch SandboxRunFollower.read(Data(body.utf8)) {
            case .running: "running"
            case .unreadable: "unreadable"
            case .ended(let outcome, _): outcome.rawValue
            }
        }
        #expect(read(#"{"run":{}}"#) == "unreadable")
        #expect(read(#"{"run":{"status":"weird"}}"#) == "unreadable")
        #expect(read(#"[]"#) == "unreadable")
        #expect(read(#"{"run":{"status":"failed"},"receipt":{}}"#) == "unreadable")
        // A terminal status before its receipt is written: the Run's end is the receipt.
        #expect(read(#"{"run":{"status":"failed"},"receipt":null}"#) == "running")
        #expect(read(Self.running) == "running")
        #expect(read(Self.succeeded) == "succeeded")
        #expect(read(Self.cancelled) == "cancelled")
        #expect(read(#"{"run":{"status":"failed"},"receipt":{"status":"failed","timedOut":true}}"#) == "timedOut")
        #expect(read(#"{"run":{"status":"failed"},"receipt":{"status":"failed","timedOut":false}}"#) == "failed")
    }

    @Test func anEndedRunsCardOutlivesARelaunch() async throws {
        let server = Server()
        await server.script("r1", [.success(Self.succeeded)])
        let defaults = try defaults()
        let (first, _) = follower(server, defaults: defaults)
        _ = try await first.follow(record())
        let (relaunched, _) = follower(server, defaults: defaults)
        let ended = try #require(relaunched.endedRun("r1"))
        #expect(ended.key == "key-r1" && ended.task == "Fix the flaky test\nthen push")
        let card = try #require(ended.card.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((card["receipt"] as? [String: Any])?["status"] as? String == "succeeded")
        #expect(card["run"] == nil)
    }

    @Test func aFailedWaitAnswersTheSendButTheFollowGoesOnToTheNotice() async throws {
        let server = Server()
        await server.script("r1", [.failure(.transport("offline")), .success(Self.succeeded)])
        let (follower, ends) = follower(server, defaults: try defaults())
        // The send's own answer is "no receipt in time", as the send's own poll answered it.
        await #expect(throws: CloudAPIError.timedOut("/api/runs/r1")) { try await follower.follow(record()) }
        await ends.wait(for: 1)
        #expect(ends.all.map(\.outcome) == [.succeeded])
    }

    @Test func aRelaunchResumesTheSavedRunsOfTheSignedInUser() async throws {
        let server = Server()
        await server.script("r1", [.success(Self.running)])
        let defaults = try defaults()
        let (first, _) = follower(server, defaults: defaults)
        // The send is cut off (its pane closed, the app quit) while the Run still runs.
        let r1 = record()
        let send = Task { try await first.follow(r1) }
        while !first.isPolling("r1") { await Task.yield() }
        send.cancel()
        _ = try? await send.value
        first.stop()
        #expect(first.following.map(\.id) == ["r1"])
        await server.script("r1", [.success(Self.succeeded)])
        let (relaunched, ends) = follower(server, defaults: defaults)
        relaunched.account(nil) // the session still loading keeps the saved Runs
        #expect(relaunched.following.map(\.id) == ["r1"])
        relaunched.account("u1")
        await ends.wait(for: 1)
        #expect(ends.all.map(\.outcome) == [.succeeded])
        #expect(relaunched.following.isEmpty)
    }

    @Test func aSignOutStopsEveryFollowAndAnotherAccountDropsTheOthersRuns() async throws {
        let server = Server()
        await server.script("r1", [.success(Self.running)])
        await server.script("r2", [.success(Self.running)])
        let (follower, ends) = follower(server, defaults: try defaults())
        follower.account("u1")
        let (r1, r2) = (record("r1"), record("r2", user: "u1"))
        let send = Task { try await follower.follow(r1) }
        await #expect(throws: CloudAPIError.notSignedIn) {
            while !follower.isPolling("r1") { await Task.yield() }
            follower.account(nil)
            _ = try await send.value
        }
        #expect(follower.following.isEmpty)
        #expect(!follower.isPolling("r1"))
        let other = Task { try await follower.follow(r2) }
        while !follower.isPolling("r2") { await Task.yield() }
        follower.account("u2")
        await #expect(throws: CloudAPIError.notSignedIn) { _ = try await other.value }
        #expect(follower.following.isEmpty)
        #expect(ends.all.isEmpty)
    }

    @Test func theBannerReadsTheTasksFirstLineAndTheOutcome() {
        func end(_ task: String, _ outcome: SandboxRunEnd.Outcome) -> SandboxRunEnd {
            SandboxRunEnd(record: SandboxRunRecord(id: "r", task: task, key: "k", user: "u", team: nil, started: Date()),
                          outcome: outcome, snapshot: Data())
        }
        #expect(SandboxRunNotices.text(end("\n  Fix the flaky test  \nthen push", .succeeded)) == ("Fix the flaky test", "Run finished"))
        #expect(SandboxRunNotices.text(end("x", .failed)).body == "Run failed")
        #expect(SandboxRunNotices.text(end("x", .timedOut)).body == "Run timed out")
        #expect(SandboxRunNotices.text(end("x", .cancelled)).body == "Run cancelled")
        let long = SandboxRunNotices.text(end(String(repeating: "a", count: 300), .succeeded)).title
        #expect(long.count == 120 && long.hasSuffix("…"))
    }

    @Test func aRestoredPageShowsTheEndedSendAsItsOwn() async throws {
        let seed = AgentPaneSeedSource(AgentPaneSeed())
        #expect(seed.holdsOnlyFolder)
        let snapshot = try #require(try JSONSerialization.jsonObject(with: Data(Self.succeeded.utf8)) as? [String: Any])
        seed.sandboxResult = ("Fix it", "key-r1", snapshot)
        // A restored page never adopts the prewarmed spare: the spare's page already read its state.
        #expect(!seed.holdsOnlyFolder)
        let model = AgentPaneModel(host: NoHost(), seed: seed)
        #expect(model.sandboxRuns.holds(key: "key-r1"))
        let state = await model.respond(to: .sandboxState(wait: false))
        let value = state["value"] as? [String: Any]
        #expect(value?["key"] as? String == "key-r1")
        #expect(((value?["reply"] as? [String: Any])?["value"] as? [String: Any])?["receipt"] != nil)
        // The tab's one send is spent.
        #expect(model.sandboxRuns.isRunning == false)
    }
}

/// A clock whose sleeps end at once (the follower's Backoff after a failed wait).
private struct ImmediateRunClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration = .zero
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant() }
    var minimumResolution: Duration { .nanoseconds(1) }
    func sleep(until _: Instant, tolerance _: Duration?) async throws { try Task.checkCancellation() }
}
