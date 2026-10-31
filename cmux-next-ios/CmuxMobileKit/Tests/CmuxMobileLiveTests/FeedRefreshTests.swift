import CmuxAgentQuestion
import CmuxMobileAgentChat
import CmuxMobileFeed
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The Mac's answer to `_acpmux/watch`, changeable between calls.
final class WatchReply: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    init(_ value: String) { self.value = value }
    var current: String {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Pull to refresh re-reads the Mac (acpmux watch and open asks), and with
/// no Mac behind the Feed nothing is marked answered.
@MainActor
@Suite struct FeedRefreshTests {
    static let waiting = #"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"fake","cwd":"/tmp/w","status":"waiting","pendingPermissions":1,"lastSeq":3,"preview":"Done","lastTurn":{"status":"completed","turnId":"t9","endedAt":1000}}]}"#
    static let idle = #"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"fake","cwd":"/tmp/w","status":"idle","pendingPermissions":0,"lastSeq":4,"preview":"Done","lastTurn":{"status":"completed","turnId":"t9","endedAt":1000}}]}"#

    static func mac(_ watch: WatchReply) -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch": return [reply(watch.current)]
            case "_acpmux/events":
                return [reply(#"{"events":[{"sessionId":"s1","seq":2,"kind":"permission_request","msg":{"permissionId":"old","request":{"toolCall":{"toolCallId":"o","title":"ls","kind":"execute"},"options":[]}}},{"sessionId":"s1","seq":3,"kind":"permission_decision","msg":{"permissionId":"old"}},{"sessionId":"s1","seq":3,"kind":"permission_request","msg":{"permissionId":"perm","request":{"toolCall":{"toolCallId":"c","title":"rm","kind":"execute"},"options":[{"optionId":"deny","name":"Deny","kind":"reject_once"}]}}}]}"#)]
            default: return [reply("{}")]
            }
        }
    }

    @Test func refreshReadsHistoryAndOpenAsksThenResolvesAnswered() async throws {
        let watch = WatchReply(Self.waiting)
        let hub = AcpmuxHub()
        await hub.bind(try await Self.mac(watch).openChannel(service: "acpmux", args: [:]))
        let store = FeedStore(items: [])
        let feed = LiveFeed(store: store, hub: hub, place: { _ in nil })
        store.actions = feed

        await store.refresh()
        #expect(store.refreshError == nil)
        #expect(Set(store.items.map(\.id)) == ["ask-perm", "turn-s1-t9"])
        #expect(store.item(id: "ask-perm")?.needsYou == true)

        // The ask was answered on the Mac: the next refresh resolves it.
        watch.current = Self.idle
        await store.refresh()
        #expect(store.item(id: "ask-perm")?.resolution == "Answered")
        #expect(store.items.count == 2)
    }

    /// A list past acpmux's reply budget comes in pages: the watch's first rows and a
    /// `nextCursor`, the rest from `_acpmux/sessions {cursor}` (no `enabled`). The hub's
    /// bind and a refresh both see every session.
    @Test func bindAndRefreshFollowTheWatchCursor() async throws {
        let mac = MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            let params = object["params"] as? [String: Any] ?? [:]
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch":
                return [reply(#"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"fake","cwd":"/tmp/w","status":"idle","pendingPermissions":0,"lastSeq":4,"preview":"Done","lastTurn":{"status":"completed","turnId":"t9","endedAt":1000}}],"nextCursor":"c1"}"#)]
            case "_acpmux/sessions" where params["cursor"] as? String == "c1" && params["enabled"] == nil:
                return [reply(#"{"sessions":[{"sessionId":"s2","name":"Ship","harness":"fake","cwd":"/tmp/w","status":"idle","pendingPermissions":0,"lastSeq":2,"preview":"Shipped","lastTurn":{"status":"completed","turnId":"t8","endedAt":1000}}]}"#)]
            default: return [reply(#"{"sessions":[]}"#)]
            }
        }
        let hub = AcpmuxHub()
        await hub.bind(try await mac.openChannel(service: "acpmux", args: [:]))
        #expect(Set(hub.sessions.keys) == ["s1", "s2"])

        let store = FeedStore(items: [])
        let feed = LiveFeed(store: store, hub: hub, place: { _ in nil })
        store.actions = feed
        await store.refresh()
        #expect(store.refreshError == nil)
        #expect(Set(store.items.map(\.id)) == ["turn-s1-t9", "turn-s2-t8"])
    }

    @Test func retryAfterFailureCallsTheFeedLoader() async throws {
        let store = FeedStore(items: [])
        await store.refresh()
        #expect(store.refreshError != nil)
        let watch = WatchReply(Self.waiting)
        let hub = AcpmuxHub()
        await hub.bind(try await Self.mac(watch).openChannel(service: "acpmux", args: [:]))
        let feed = LiveFeed(store: store, hub: hub, place: { _ in nil })
        store.actions = feed
        var reconnects = 0
        await store.retry { reconnects += 1 }
        #expect(reconnects == 1)
        #expect(store.refreshError == nil)
        #expect(Set(store.items.map(\.id)) == ["ask-perm", "turn-s1-t9"])
    }

    @Test func retryWaitsForDelayedReconnectionBeforeRefreshing() async throws {
        let store = FeedStore(items: [])
        let hub = AcpmuxHub()
        let feed = LiveFeed(store: store, hub: hub, place: { _ in nil })
        store.actions = feed
        await store.refresh()
        #expect(store.refreshError != nil)
        let (started, signalStarted) = AsyncStream<Void>.makeStream()
        let (ready, signalReady) = AsyncStream<Void>.makeStream()
        let channel = try await Self.mac(WatchReply(Self.waiting)).openChannel(service: "acpmux", args: [:])
        let retry = Task { @MainActor in
            await store.retry {
                signalStarted.yield(())
                for await _ in ready { break }
                await hub.bind(channel)
            }
        }
        for await _ in started { break }
        #expect(store.refreshError != nil)
        #expect(!hub.isReady)
        signalReady.yield(())
        await retry.value
        signalStarted.finish()
        signalReady.finish()
        #expect(store.refreshError == nil)
        #expect(Set(store.items.map(\.id)) == ["ask-perm", "turn-s1-t9"])
        await hub.bind(nil)
    }

    @Test func refreshWithNoMacFailsVisibly() async {
        let store = FeedStore(items: [])
        await store.refresh()
        #expect(store.refreshError == FeedStore.notConnectedMessage)
        store.clearRefreshError()
        #expect(store.refreshError == nil)
    }

    @Test func requestAfterRemoteCloseFailsWithoutWaitingForTimeout() async throws {
        let channel = try await Self.mac(WatchReply(Self.idle)).openChannel(service: "acpmux", args: [:])
        let connection = AcpmuxConnection(channel: channel)
        await connection.start()
        await channel.close(code: "eof", reason: "remote closed")
        // Notification completion is the connection's real receive-loop teardown.
        for await _ in connection.notifications {}
        do {
            _ = try await connection.request("_acpmux/watch", .object([:]), timeout: .seconds(1))
            Issue.record("A closed connection accepted a request")
        } catch let error as LinkError {
            #expect(error.code == "closed")
        }
    }

    @Test(arguments: ["initialize", "_acpmux/watch"])
    func unansweredHandshakeTimesOutAndCanRetry(method: String) async throws {
        let link = MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let called = object["method"] as? String else { return [] }
            if called == method { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            return [Data(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#.utf8)]
        }
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]), requestTimeout: .milliseconds(20))
        #expect(!hub.isReady)
        #expect(hub.lastError == LinkController.reason(LinkError(code: "timeout", message: "unused")))
        await hub.bind(try await Self.mac(WatchReply(Self.idle)).openChannel(service: "acpmux", args: [:]))
        #expect(hub.isReady)
        #expect(hub.lastError == nil)
        await hub.bind(nil)
    }

    @Test(arguments: ["initialize", "_acpmux/watch"])
    func cancellingUnansweredHandshakeReleasesTheRequest(method: String) async throws {
        let (requests, sent) = AsyncStream<Void>.makeStream()
        let link = MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let called = object["method"] as? String else { return [] }
            if called == method {
                sent.yield(())
                return []
            }
            let id = object["id"].map { "\($0)" } ?? "null"
            return [Data(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#.utf8)]
        }
        let hub = AcpmuxHub()
        let channel = try await link.openChannel(service: "acpmux", args: [:])
        let task = Task { @MainActor in await hub.bind(channel, requestTimeout: .seconds(60)) }
        for await _ in requests { break }
        let start = ContinuousClock.now
        task.cancel()
        await task.value
        sent.finish()
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(!hub.isReady)
        #expect(hub.lastError != nil)
    }

    @Test func answersWithNoMacAreNotAppliedLocally() throws {
        let request = ACPPermissionRequest(id: "p", toolCall: .init(id: "c", title: "rm", kind: .execute),
                                           options: [ACPPermissionOption(id: "allow", name: "Allow", kind: .allowOnce)])
        let item = FeedItem(id: "ask-p", kind: .permission(request), workspaceID: "ws", tabID: "t", agentName: "Claude",
                            harness: "claude", workspaceTitle: "cmux", markdown: "rm", quote: nil, createdAt: Date())
        let store = FeedStore(items: [item])
        store.respond(item.id, option: request.options[0])
        #expect(store.item(id: item.id)?.resolution == nil)
        #expect(store.item(id: item.id)?.error == FeedStore.notConnectedMessage)
        #expect(store.item(id: item.id)?.needsYou == true)
    }

    @Test func mockContentStillAnswersLocally() {
        let request = ACPPermissionRequest(id: "p", toolCall: .init(id: "c", title: "rm", kind: .execute),
                                           options: [ACPPermissionOption(id: "deny", name: "Deny", kind: .rejectOnce)])
        let item = FeedItem(id: "ask-p", kind: .permission(request), workspaceID: "ws", tabID: "t", agentName: "Claude",
                            harness: "claude", workspaceTitle: "cmux", markdown: "rm", quote: nil, createdAt: Date())
        let store = FeedStore(items: [item], answersLocally: true)
        store.respond(item.id, option: request.options[0])
        #expect(store.item(id: item.id)?.resolution == "Denied")
        #expect(store.item(id: item.id)?.error == nil)
    }

    @Test func openRequestsSkipDecidedAsks() throws {
        let records = try JSONDecoder().decode([JSONValue].self, from: Data(#"[{"kind":"permission_request","msg":{"permissionId":"a","request":{}}},{"kind":"permission_decision","msg":{"permissionId":"a"}},{"kind":"permission_request","msg":{"permissionId":"b","request":{}}}]"#.utf8))
        #expect(LiveFeed.openRequests(records).map(\.permissionID) == ["b"])
    }
}
