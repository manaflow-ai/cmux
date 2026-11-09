import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextCloud
import Foundation
import Testing

/// A sandboxed Run handed off from the app is followed by one app-level waiter
/// (``SandboxRunFollower``, whose rules and their cases are Rust's: cmux-tui/crates/cmux-cloud-tasks).
/// These cases cover its Swift side (the poll, the waiters) and ``SandboxRunNotices``: the banner reads
/// the task's first line and the outcome.
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

    private func follower(_ server: Server, defaults: UserDefaults, now: @escaping @MainActor () -> Date = { Date() }) -> (SandboxRunFollower, Ends) {
        let follower = SandboxRunFollower(wait: { id, _ in try await server.wait(id) }, defaults: defaults, now: now, clock: ImmediateRunClock())
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

    @Test func aSendThatAnsweredBeforeItsRunEndedTakesTheReceipt() async throws {
        let runs = AgentPaneSandboxRuns()
        _ = await runs.run(task: "Fix it", key: "key-r1") { AgentPaneReply.failure(code: "timeout", message: "timeout") }
        let snapshot = try #require(try JSONSerialization.jsonObject(with: Data(Self.succeeded.utf8)) as? [String: Any])
        runs.settle(key: "other", snapshot: snapshot)
        #expect(runs.settledLate == nil)
        runs.settle(key: "key-r1", snapshot: snapshot)
        #expect(runs.settledLate == "key-r1")
        let value = (await runs.state(wait: false))["value"] as? [String: Any]
        #expect(((value?["reply"] as? [String: Any])?["value"] as? [String: Any])?["receipt"] != nil)
    }

    @Test func aRunThatEndsWhileItsSendStillAnswersGivesTheSendItsReceipt() async throws {
        let runs = AgentPaneSandboxRuns()
        let snapshot = try #require(try JSONSerialization.jsonObject(with: Data(Self.succeeded.utf8)) as? [String: Any])
        // The Run ends while the send is finishing with its deadline's timeout.
        let reply = await runs.run(task: "Fix it", key: "key-r1") {
            runs.settle(key: "key-r1", snapshot: snapshot)
            return AgentPaneReply.failure(code: "timeout", message: "timeout")
        }
        #expect((reply["value"] as? [String: Any])?["receipt"] != nil)
        #expect(runs.settledLate == nil)
    }

    @Test func aFailedWaitAnswersTheSendButTheFollowGoesOnToTheNotice() async throws {
        let server = Server()
        await server.script("r1", [.failure(.transport("offline")), .success(Self.succeeded)])
        let (follower, ends) = follower(server, defaults: try defaults())
        // The send's own answer is "no receipt in time", as the send's own poll answered it.
        await #expect(throws: CloudAPIError.timedOut("cloud.runs/r1")) { try await follower.follow(record()) }
        await ends.wait(for: 1)
        #expect(ends.all.map(\.outcome) == [.succeeded])
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

    private static var kept: [AppServices] = []

    /// Issue #31040: a normal tab closed while its Run was being created is gone when the create
    /// answers. Whether the Run is incognito is read when the send starts, while the pane holds its
    /// key, so that Run keeps its banner's click and its record across a quit.
    @Test func aRunsIncognitoIsReadWhenItsSendStartsNotWhenItsCreateAnswers() async throws {
        let server = Server()
        await server.script("r1", [.success(Self.succeeded)])
        await server.script("r2", [.success(Self.succeeded)])
        let (follower, ends) = follower(server, defaults: try defaults())
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        Self.kept.append(services) // SandboxRunNotices holds its services weakly
        let notices = SandboxRunNotices(services: services, follower: follower, user: { "u1" })
        follower.onEnd = { ends.add($0) } // the banner itself is not under test
        // No tab holds either key any more: both tabs closed while their Runs were created.
        _ = try await notices.follow(id: "r1", task: "Fix it", key: "key-r1", team: "t1", incognito: false)
        _ = try await notices.follow(id: "r2", task: "Fix it", key: "key-r2", team: "t1", incognito: true)
        #expect(follower.endedRun("r1")?.record.incognito == nil, "a normal tab's Run became incognito because its tab closed")
        #expect(follower.endedRun("r2")?.record.incognito == true)
        #expect(ends.all.map(\.record.incognito) == [nil, true])
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
        #expect(AgentPaneSeedSource(AgentPaneSeed()).holdsOnlyFolder)
        #expect(!AgentPaneSeedSource(AgentPaneSeed(model: "model-x")).holdsOnlyFolder)
        #expect(!AgentPaneSeedSource(AgentPaneSeed(host: "peer-1")).holdsOnlyFolder)
        var value = AgentPaneSeed()
        value.sandboxResult = .init(task: "Fix it", key: "key-r1", card: Data(#"{"receipt":{"status":"succeeded","exitCode":0}}"#.utf8))
        // The seed a banner's click opens a workspace with (WorkspaceSpawn.firstChat) carries it to the page.
        let seed = AgentPaneSeedSource(value)
        // A restored page never adopts the prewarmed spare: the spare's page already read its state.
        #expect(!seed.holdsOnlyFolder)
        let model = AgentPaneModel(host: NoHost(), seed: seed)
        #expect(model.sandboxRuns.holds(key: "key-r1"))
        let state = await model.respond(to: .sandboxState(wait: false))
        let answer = state["value"] as? [String: Any]
        #expect(answer?["key"] as? String == "key-r1")
        #expect(((answer?["reply"] as? [String: Any])?["value"] as? [String: Any])?["receipt"] != nil)
        // The tab's one send is spent.
        #expect(model.sandboxRuns.isRunning == false)
    }
}

/// A clock whose sleeps end at once (the follower's Backoff after a failed wait).
struct ImmediateRunClock: Clock {
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
