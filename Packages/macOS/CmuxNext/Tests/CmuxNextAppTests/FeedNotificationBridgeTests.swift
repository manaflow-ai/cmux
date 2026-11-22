@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import CmuxNextSettings
import Testing

/// Notifications migration step 1 (plans/cmux-next/feed.md section 9): each
/// daemon notification becomes one feed notice, and a tab read marks exactly
/// the notices that arrived before it read.
@MainActor
struct FeedNotificationBridgeTests {
    /// A fake feed owner: records calls, answers posts with `fi_<notification id>`,
    /// and can hold posts until released (a post in flight).
    @MainActor
    final class Owner {
        var calls: [(op: String, params: [String: Any])] = []
        var holding = false
        var failPosts = false
        private var held: [CheckedContinuation<Void, Never>] = []

        func handle(_ body: [String: Any]) async throws -> [String: Any] {
            let op = body["op"] as? String ?? ""
            let params = body["params"] as? [String: Any] ?? [:]
            calls.append((op, params))
            guard op == "feed.post" else { return ["ok": true] }
            if holding { await withCheckedContinuation { held.append($0) } }
            if failPosts { throw FeedServiceError.owner(code: "feed.rate_limited", message: "") }
            let key = params["dedupe_key"] as? String ?? ""
            return ["ok": true, "value": ["item": ["id": "fi_" + (key.split(separator: ":").last.map(String.init) ?? "")]]]
        }

        func release() {
            holding = false
            let list = held
            held = []
            for c in list { c.resume() }
        }

        var reads: [[String]] { calls.filter { $0.op == "feed.read" }.map { $0.params["items"] as? [String] ?? [] } }
        var posts: Int { calls.filter { $0.op == "feed.post" }.count }
    }

    private func notice(_ id: UInt64, tab: String = "tab-1", level: NotificationLevel = .info, title: String = "Done") -> FeedNotificationBridge.Notice {
        .init(notification: id, daemonSession: "S", title: title, body: "body \(id)", level: level, tab: tab, workspace: "ws-1", label: "agent")
    }

    private func bridge(_ owner: Owner, signedIn: Bool = true, now: @escaping @MainActor () -> Date = Date.init) -> FeedNotificationBridge {
        FeedNotificationBridge(owner: { _, body in try await owner.handle(body) }, isSignedIn: { signedIn }, now: now)
    }

    /// Settles every queued main-actor hop until the bridge has nothing in flight.
    private func settle(_ bridge: FeedNotificationBridge) async {
        for _ in 0..<4 {
            await bridge.drain()
            await Task.yield()
        }
    }

    @Test func postBodyIsOneNoticePerDaemonNotification() throws {
        let body = FeedNotificationBridge.postBody(notice(7, level: .error))
        #expect(body["op"] as? String == "feed.post")
        #expect(body["idempotency_key"] as? String == "notify:S:7")
        let params = try #require(body["params"] as? [String: Any])
        #expect(params["type"] as? String == "notice")
        #expect(params["kind"] as? String == "notice")
        #expect(params["dedupe_key"] as? String == "notify:S:7")
        #expect(params["priority"] as? String == "high")
        #expect(params["thread"] as? String == "tab:tab-1")
        #expect(params["body"] as? String == "body 7")
        #expect((params["context"] as? [String: Any])?["workspace"] as? String == "ws-1")
        #expect((params["poster"] as? [String: Any])?["label"] as? String == "agent")
        #expect(FeedNotificationBridge.postBody(notice(8))["params"].flatMap { ($0 as? [String: Any])?["priority"] as? String } == "normal")
    }

    @Test func titlesAndBodiesAreCutToTheOwnerLimits() throws {
        var long = notice(1, title: String(repeating: "t", count: 500))
        long.body = String(repeating: "b", count: 5000)
        let params = try #require(FeedNotificationBridge.postBody(long)["params"] as? [String: Any])
        #expect((params["title"] as? String)?.count == 200)
        #expect((params["body"] as? String)?.count == 4096)
        let empty = try #require(FeedNotificationBridge.postBody(notice(2, title: ""))["params"] as? [String: Any])
        #expect(empty["title"] as? String == "cmux")
    }

    @Test func signedOutPostsNothing() async {
        let owner = Owner()
        let bridge = bridge(owner, signedIn: false)
        bridge.post(notice(1))
        await settle(bridge)
        #expect(owner.calls.isEmpty)
    }

    @Test func aReadAfterThePostSettlesReadsThatItem() async {
        let owner = Owner()
        let bridge = bridge(owner)
        bridge.post(notice(1))
        await settle(bridge)
        bridge.read(tab: "tab-1")
        await settle(bridge)
        #expect(owner.reads == [["fi_1"]])
    }

    @Test func aReadWhileThePostIsInFlightReadsItWhenItSettles() async {
        let owner = Owner()
        owner.holding = true
        let bridge = bridge(owner)
        bridge.post(notice(1))
        await Task.yield()
        bridge.read(tab: "tab-1")
        #expect(owner.reads.isEmpty)
        owner.release()
        await settle(bridge)
        #expect(owner.reads == [["fi_1"]])
    }

    @Test func aReadNeverCoversANotificationThatArrivedAfterIt() async {
        let owner = Owner()
        let bridge = bridge(owner)
        bridge.post(notice(1))
        await settle(bridge)
        bridge.read(tab: "tab-1")
        bridge.post(notice(2))
        await settle(bridge)
        #expect(owner.reads == [["fi_1"]])
        bridge.read(tab: "tab-1")
        await settle(bridge)
        #expect(owner.reads == [["fi_1"], ["fi_2"]])
    }

    @Test func readsAreScopedToTheirTabAndSentOnce() async {
        let owner = Owner()
        let bridge = bridge(owner)
        bridge.post(notice(1, tab: "tab-1"))
        bridge.post(notice(2, tab: "tab-2"))
        await settle(bridge)
        bridge.read(tab: "tab-2")
        bridge.read(tab: "tab-2")
        await settle(bridge)
        #expect(owner.posts == 2)
        #expect(owner.reads == [["fi_2"]])
    }

    @Test func aFailedPostReadsNothingAndIsLogged() async {
        let owner = Owner()
        owner.failPosts = true
        let bridge = bridge(owner)
        bridge.post(notice(1))
        await settle(bridge)
        bridge.read(tab: "tab-1")
        await settle(bridge)
        #expect(owner.reads.isEmpty)
        #expect(bridge.log.contains { $0.contains("failed: feed.rate_limited") })
    }

    @Test func postsForOneTabCoalesceWhileOneIsInFlight() async {
        let owner = Owner()
        owner.holding = true
        let bridge = bridge(owner)
        bridge.post(notice(1))
        await Task.yield()
        bridge.post(notice(2))
        bridge.post(notice(3))
        owner.release()
        await settle(bridge)
        let keys = owner.calls.filter { $0.op == "feed.post" }.map { $0.params["dedupe_key"] as? String }
        #expect(keys == ["notify:S:1", "notify:S:3"])
        #expect(bridge.log.contains("coalesced 2"))
    }

    @Test func theClientCapsPostsPerMinute() async {
        let owner = Owner()
        var clock = Date(timeIntervalSince1970: 1_000)
        let bridge = bridge(owner, now: { clock })
        for id in 1...UInt64(FeedNotificationBridge.maxPostsPerMinute + 5) {
            bridge.post(notice(id, tab: "tab-\(id)"))
        }
        await settle(bridge)
        #expect(owner.posts == FeedNotificationBridge.maxPostsPerMinute)
        clock = clock.addingTimeInterval(61)
        bridge.post(notice(999, tab: "tab-x"))
        await settle(bridge)
        #expect(owner.posts == FeedNotificationBridge.maxPostsPerMinute + 1)
    }

    @Test func aReadTabIsForgotten() async {
        let owner = Owner()
        let bridge = bridge(owner)
        for id in 1...UInt64(20) { bridge.post(notice(id, tab: "tab-\(id)")) }
        await settle(bridge)
        #expect(bridge.trackedTabs == 20)
        for id in 1...20 { bridge.read(tab: "tab-\(id)") }
        await settle(bridge)
        #expect(bridge.trackedTabs == 0)
    }

    @Test func knownSecretShapesAreRedactedBeforePosting() throws {
        let cases: [(String, String)] = [
            ("export OPENAI_API_KEY=sk-proj-abcdefghijklmnop1234", "sk-proj-abcdefghijklmnop1234"),
            ("token ghp_abcdefghijklmnopqrstuvwxyz0123", "ghp_abcdefghijklmnopqrstuvwxyz0123"),
            ("Authorization: Bearer abc.def-123456", "abc.def-123456"),
            ("password=hunter2hunter2", "hunter2hunter2"),
            ("jwt eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.SflKxwRJSMeKKF2QT4", "eyJhbGciOiJIUzI1"),
            ("key AKIAABCDEFGHIJKLMNOP done", "AKIAABCDEFGHIJKLMNOP"),
            ("db postgres://admin:s3cretpw@db.example.com/x", "s3cretpw"),
            ("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaA==\n-----END OPENSSH PRIVATE KEY-----", "b3BlbnNzaA"),
        ]
        for (text, secret) in cases {
            var n = notice(1, title: text)
            n.body = text
            let params = try #require(FeedNotificationBridge.postBody(n)["params"] as? [String: Any])
            #expect(!(params["title"] as? String ?? "").contains(secret), "title kept \(secret)")
            #expect(!(params["body"] as? String ?? "").contains(secret), "body kept \(secret)")
            #expect((params["body"] as? String ?? "").contains(FeedSecretScrubber.marker))
        }
        #expect(FeedSecretScrubber.scrub("Build 42 failed in 3 tests") == "Build 42 failed in 3 tests")
    }

    @Test func mirrorSettingsDecideWhatLeavesTheMac() throws {
        let data = Data(#"{"notification": 1, "title": "T", "body": "B", "level": "info"}"#.utf8)
        let n = try JSONDecoder().decode(DaemonNotification.self, from: data)
        var mirror = FeedMirrorPreferences()
        #expect(NotificationCenterService.feedContent(n, source: .terminal, mirror: mirror) == nil)
        #expect(NotificationCenterService.feedContent(n, source: .agent, mirror: mirror)! == ("T", "B"))
        #expect(NotificationCenterService.feedContent(n, source: .cli, mirror: mirror)! == ("T", "B"))
        mirror.terminal = .title
        #expect(NotificationCenterService.feedContent(n, source: .terminal, mirror: mirror)! == ("T", ""))
        mirror.terminal = .full
        #expect(NotificationCenterService.feedContent(n, source: .terminal, mirror: mirror)! == ("T", "B"))
        mirror.agents = false
        #expect(NotificationCenterService.feedContent(n, source: .agent, mirror: mirror) == nil)
    }
}
