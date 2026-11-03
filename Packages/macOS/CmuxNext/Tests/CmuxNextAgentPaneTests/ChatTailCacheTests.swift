import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The host's chat tails at the ops the page calls (`chat.tail`, `chat.tail.get`): a chat another
/// tab read opens drawn instead of blank, on either host, and the bounds that keep this from
/// becoming somewhere a transcript lives.
///
/// `agent.pageHost` is off by default, so the pane's own host is the path production takes; both
/// are held here, because one store serves both.
@Suite(.serialized)
@MainActor
struct ChatTailCacheTests {
    private static func resetCache() {
        AgentPaneTailCache.shared.clear()
        AgentPaneTailCache.shared.resume()
    }

    private actor HeldSnapshotHost: AgentPaneHostProviding {
        let started: AsyncStream<Void>
        private let signal: AsyncStream<Void>.Continuation
        private var reply: CheckedContinuation<Data?, Never>?
        init() { (started, signal) = AsyncStream.makeStream(of: Void.self) }
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { .mock }
        func peerSnapshot(sessionId: String) async -> Data? {
            await withCheckedContinuation { continuation in
                reply = continuation
                signal.yield(())
            }
        }
        func deliver(_ data: Data) { reply?.resume(returning: data); reply = nil; signal.finish() }
    }

    @Test func signOutDropsQueuedReplyAndRepostsUntilNextSignIn() async throws {
        Self.resetCache()
        defer { Self.resetCache() }
        let host = HeldSnapshotHost()
        let started = await host.started
        let reply = Task {
            let value = await AgentPaneTailCache.reply(to: "chat.tail.get", params: ["sessionId": "s-1"], host: host)
            return Self.value(value) is NSNull
        }
        for await _ in started { break }
        AgentPaneTailCache.shared.clear()
        _ = Self.bridge("chat.tail", ["sessionId": "s-1", "tail": Self.tail(3)])
        #expect(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-1"])) is NSNull)
        let disabled = await AgentPaneTailCache.reply(to: "chat.tail.get", params: ["sessionId": "s-1"], host: host)
        #expect(Self.value(disabled) is NSNull)
        // A new sign-in cannot make the old lifecycle's queued reply current again.
        AgentPaneTailCache.shared.resume()
        await host.deliver(try JSONSerialization.data(withJSONObject: Self.tail(4)))
        #expect(await reply.value)
        _ = Self.bridge("chat.tail", ["sessionId": "s-1", "tail": Self.tail(2)])
        #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-1"]))) == [1, 2])
    }

    private actor SnapshotHost: AgentPaneHostProviding {
        let snapshot: Data
        var reads = 0
        init(_ snapshot: Data) { self.snapshot = snapshot }
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { .mock }
        func peerSnapshot(sessionId: String) async -> Data? {
            reads += 1
            return snapshot
        }
    }

    @Test func legacyBridgeWriteUsesItsPageGeneration() async {
        Self.resetCache()
        defer { Self.resetCache() }
        let old = AgentPaneTailCache.shared.generation
        AgentPaneTailCache.shared.clear()
        AgentPaneTailCache.shared.resume()
        let params: [String: Any] = ["sessionId": "s-1", "tail": Self.tail(3)]
        _ = await AgentPaneTailCache.reply(to: "chat.tail", params: params, host: nil, pageGeneration: old)
        #expect(AgentPaneTailCache.shared.tail(for: "s-1") == nil)
        _ = await AgentPaneTailCache.reply(to: "chat.tail", params: params, host: nil,
                                          pageGeneration: AgentPaneTailCache.shared.generation)
        #expect(AgentPaneTailCache.shared.tail(for: "s-1") != nil)
    }

    @Test func oldProviderCannotRepostAfterSignInButCanStillRead() async throws {
        Self.resetCache()
        defer { Self.resetCache() }
        let old = AgentPageProvider { _ in nil }
        let params: JSONValue = .object(["sessionId": .string("s-1"), "tail": JSONValue(foundation: Self.tail(3))!])
        AgentPaneTailCache.shared.clear()
        AgentPaneTailCache.shared.resume()
        _ = try await old.call(AgentPageOps.namespace + "chat.tail", params: params, context: Self.context)
        #expect(AgentPaneTailCache.shared.tail(for: "s-1") == nil)
        let newer = AgentPageProvider { _ in nil }
        _ = try await newer.call(AgentPageOps.namespace + "chat.tail", params: params, context: Self.context)
        #expect(AgentPaneTailCache.shared.tail(for: "s-1") != nil)
        // A stale page's forget/hover write must not erase or replace the new lifecycle's tail.
        _ = try await old.call(AgentPageOps.namespace + "chat.tail",
                              params: .object(["sessionId": .string("s-1")]), context: Self.context)
        _ = try await old.call(AgentPageOps.namespace + "chat.tail",
                              params: .object(["sessionId": .string("s-1"), "ifNewer": .bool(true),
                                               "tail": JSONValue(foundation: Self.tail(5))!]), context: Self.context)
        let read = try await old.call(AgentPageOps.namespace + "chat.tail.get",
                                      params: .object(["sessionId": .string("s-1")]), context: Self.context)
        #expect(Self.seqs(read.foundationObject) == [1, 2, 3])
        let snapshot = Self.tail(2)
        old.tailHost = SnapshotHost(try JSONSerialization.data(withJSONObject: snapshot))
        let fresh = try await old.call(AgentPageOps.namespace + "chat.tail.get",
                                       params: .object(["sessionId": .string("s-2")]), context: Self.context)
        #expect(Self.seqs(fresh.foundationObject) == [1, 2])
    }

    @Test func bothHostsForwardColdMissesBeforeHandshakeAndPreferMemory() async throws {
        Self.resetCache()
        defer { Self.resetCache() }
        let snapshot: [String: Any] = ["peer": "vm", "sessionId": "s-1", "generation": 42,
                                      "capturedAt": 123, "stale": true, "events": Self.tail(3)["events"]!]
        let host = SnapshotHost(try JSONSerialization.data(withJSONObject: snapshot))
        let legacy = await AgentPaneTailCache.reply(to: "chat.tail.get", params: ["sessionId": "s-1"], host: host)
        let value = try #require(Self.value(legacy) as? [String: Any])
        #expect(value["stale"] as? Bool == true)
        #expect(value["generation"] as? Int == 42)
        let provider = AgentPageProvider { _ in nil }
        provider.tailHost = host
        let page = try await provider.call(AgentPageOps.namespace + "chat.tail.get",
                                          params: .object(["sessionId": .string("s-1")]), context: Self.context)
        #expect(page == JSONValue(foundation: snapshot))
        #expect(await host.reads == 2)
        _ = Self.bridge("chat.tail", ["sessionId": "s-1", "tail": Self.tail(5)])
        let warm = await AgentPaneTailCache.reply(to: "chat.tail.get", params: ["sessionId": "s-1"], host: host)
        #expect(Self.seqs(Self.value(warm)) == [1, 2, 3, 4, 5])
        #expect(await host.reads == 2)
    }

    static let context = PageCallContext(page: PageDescriptor.agent.id)

    /// A page tail of `count` records, as the page's own shape.
    static func tail(_ count: Int, exhausted: Bool = false, mark: String = "a") -> [String: Any] {
        [
            "events": (1...max(1, count)).map { ["seq": $0, "kind": "user_message", "msg": ["text": "\(mark)\($0)"]] },
            "historyExhausted": exhausted,
            "queue": [],
            "configSeq": 0,
            "usageFromSeq": 0,
        ]
    }

    static func bridge(_ method: String, _ params: [String: Any]) -> [String: Any] {
        AgentPaneTailCache.reply(to: method, params: params)
    }

    static func value(_ reply: [String: Any]) -> Any? {
        #expect(reply["ok"] as? Bool == true, "the host refused the request: \(reply)")
        return reply["value"]
    }

    /// The records of a tail the host answered, by their `seq`.
    static func seqs(_ answered: Any?) -> [Int] {
        guard let object = answered as? [String: Any], let events = object["events"] as? [[String: Any]] else { return [] }
        return events.compactMap { $0["seq"] as? Int }
    }

    @Test func aChatAnotherTabReadIsHandedBackToANewPage() throws {
        defer { Self.resetCache() }
        Self.resetCache()

        // Nothing read yet: a new tab is told there is no tail and opens from acpmux.
        #expect(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-1"])) is NSNull)

        // One tab reads the chat and hands its tail over; another asks for it before it attaches.
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-1", "tail": Self.tail(3)]))
        #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-1"]))) == [1, 2, 3])
        // Another chat's tail is not this chat's.
        #expect(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-2"])) is NSNull)

        // The page read on, so what it hands over now replaces what it handed over before.
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-1", "tail": Self.tail(5, mark: "b")]))
        #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-1"]))) == [1, 2, 3, 4, 5])

        // A page that no longer stands behind the transcript (its attach failed, the chat was
        // purged) says so, and the next tab opens cold rather than on rows nothing backs.
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-1"]))
        #expect(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-1"])) is NSNull)
    }

    /// The bound that keeps #23064 from coming back on this side: a tail over the cap is refused
    /// WHOLE. Cutting one and keeping its `historyExhausted` would tell the next page the chat has
    /// no older turns, and the reader could not scroll up to them.
    /// A sidebar hover's hand-over (`ifNewer`, HQ#5914) is compared and kept in one step in the
    /// host: it never goes backwards, whichever page wrote last, and a tie keeps the fuller tail
    /// kept (the Codex reviews of #30739 at ea872ad4 and ed87dd77).
    @Test func aHoversHandOverNeverReplacesTheSameOrANewerTail() throws {
        defer { Self.resetCache() }
        Self.resetCache()
        // Nothing kept: the hover's tail goes in.
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-1", "tail": Self.tail(2, mark: "hover"), "ifNewer": true]))
        #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-1"]))) == [1, 2])
        // Another tab read on to 5: kept as ever.
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-1", "tail": Self.tail(5, mark: "tab")]))
        // A hover's older copy, written after it, is not kept.
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-1", "tail": Self.tail(3, mark: "hover"), "ifNewer": true]))
        #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-1"]))) == [1, 2, 3, 4, 5])
        // One that ends on the same record, but holds less of the chat, is not kept either.
        let shorter: [String: Any] = ["events": [["seq": 5, "kind": "user_message", "msg": ["text": "hover5"]]], "historyExhausted": false,
                                      "queue": [], "configSeq": 0, "usageFromSeq": 0]
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-1", "tail": shorter, "ifNewer": true]))
        #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-1"]))) == [1, 2, 3, 4, 5])
        // A newer one is.
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-1", "tail": Self.tail(6, mark: "hover"), "ifNewer": true]))
        #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-1"]))) == [1, 2, 3, 4, 5, 6])
        // The page host's op keeps the same rule.
        let page = JSONValue.object(["sessionId": .string("s-1"), "ifNewer": .bool(true),
                                     "tail": try #require(JSONValue(foundation: Self.tail(4, mark: "hover")))])
        _ = try AgentPageProvider.tail("chat.tail", params: page, op: "chat.tail")
        #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-1"]))) == [1, 2, 3, 4, 5, 6])
    }

    @Test func aTailOverTheCapIsRefusedWholeAndNeverCut() throws {
        defer { Self.resetCache() }
        Self.resetCache()
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-1", "tail": Self.tail(10, exhausted: true)]))

        let over = Self.tail(AgentPaneTailCache.events + 1, exhausted: true, mark: "c")
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-1", "tail": over]))
        // Not cut to the cap, and not the older tail either: nothing is kept for that chat.
        #expect(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-1"])) is NSNull)

        // Exactly the cap is kept, whole.
        let full = Self.tail(AgentPaneTailCache.events, mark: "d")
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-2", "tail": full]))
        #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-2"]))).count == AgentPaneTailCache.events)

        // A tail with no records is not a tail.
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-3", "tail": ["events": [], "historyExhausted": false]]))
        #expect(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-3"])) is NSNull)
    }

    /// What is held is bounded, so this cannot become a place every chat of a long day lives.
    @Test func onlyTheMostRecentChatsAreKept() throws {
        defer { Self.resetCache() }
        Self.resetCache()
        for chat in 1...(AgentPaneTailCache.chats + 4) {
            _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-\(chat)", "tail": Self.tail(2)]))
        }
        // The four oldest are gone; the cap's worth of newest are there.
        for chat in 1...4 {
            #expect(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-\(chat)"])) is NSNull)
        }
        for chat in 5...(AgentPaneTailCache.chats + 4) {
            #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-\(chat)"]))) == [1, 2])
        }
        // Reading a chat again makes it the most recent, so it outlives chats remembered after it.
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-5", "tail": Self.tail(2)]))
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-99", "tail": Self.tail(2)]))
        #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-5"]))) == [1, 2])
    }

    /// Signing out drops them with the rest of the session's state (CloudService.signOut), which
    /// is the whole of forgetting them, because none of it is on disk.
    @Test func signingOutForgetsEveryTail() throws {
        defer { Self.resetCache() }
        Self.resetCache()
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-1", "tail": Self.tail(3)]))
        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-2", "tail": Self.tail(3)]))
        Self.resetCache()
        #expect(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-1"])) is NSNull)
        #expect(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-2"])) is NSNull)
    }

    /// Both hosts read and write the one store, so a pane with `agent.pageHost` on and one without
    /// hand each other the same chats.
    @Test func thePageHostAndThePanesOwnHostShareTheOneStore() async throws {
        defer { Self.resetCache() }
        Self.resetCache()
        let provider = AgentPageProvider { _ in nil }

        _ = Self.value(Self.bridge("chat.tail", ["sessionId": "s-1", "tail": Self.tail(3)]))
        let onPageHost = try await provider.call(
            AgentPageOps.namespace + "chat.tail.get", params: .object(["sessionId": .string("s-1")]), context: Self.context)
        guard case .object(let fields) = onPageHost, case .array(let events)? = fields["events"] else {
            Issue.record("the page host answered no tail for a chat the pane's own host kept: \(onPageHost)")
            return
        }
        #expect(events.count == 3)

        _ = try await provider.call(
            AgentPageOps.namespace + "chat.tail",
            params: .object(["sessionId": .string("s-2"), "tail": JSONValue(foundation: Self.tail(4))!]),
            context: Self.context)
        #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-2"]))).count == 4)
    }

    /// Both hosts branch on ``AgentPaneTailCache/handles(method:)``, and it names its two ops rather
    /// than matching the `chat.tail` prefix. `reply(to:params:)` takes anything that is not `.get`
    /// as a write, so a later `chat.tail.forget` matched by prefix would have ERASED the chat's tail
    /// instead of being refused — and on the pane's own host a prefix would swallow it before
    /// ``AgentPaneRequest`` could give it to the model. The same reason `AgentPaneScrollAnchors`
    /// names its ops, two lines above this branch in `AgentPageProvider`.
    @Test func onlyTheTwoOpsThisStoreServesAreTakenAsItsOwn() throws {
        #expect(AgentPaneTailCache.handles(method: "chat.tail"))
        #expect(AgentPaneTailCache.handles(method: "chat.tail.get"))
        #expect(!AgentPaneTailCache.handles(method: "chat.tail.forget"))
        #expect(!AgentPaneTailCache.handles(method: "chat.tail.anything"))
        #expect(!AgentPaneTailCache.handles(method: "chat.tailgate"))
        #expect(!AgentPaneTailCache.handles(method: "chat.scrollAnchor"))
    }

    @Test func aRequestWithoutAChatIsRefused() throws {
        defer { Self.resetCache() }
        #expect(Self.bridge("chat.tail.get", [:])["ok"] as? Bool == false)
        #expect(Self.bridge("chat.tail", ["sessionId": ""])["ok"] as? Bool == false)
        #expect(Self.bridge("chat.tail.forget", ["sessionId": "s-1"])["ok"] as? Bool == false)
    }

    /// A tail too large to keep is refused whole, so this never becomes megabytes of a person's
    /// text held per chat. The page bounds what it hands over, but the bound has to hold here too:
    /// a page that bounds wrongly, or not at all, is the case this is for.
    ///
    /// The bytes are in the `queue` rather than the records, which is the hole this closes: a
    /// queued prompt carries its whole text, and no record count bounds it.
    @Test func aTailTooLargeToKeepIsRefusedAndDropsWhatWasKept() throws {
        defer { Self.resetCache() }
        _ = Self.bridge("chat.tail", ["sessionId": "s-9", "tail": Self.tail(3)])
        #expect(Self.seqs(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-9"]))).count == 3)

        var huge = Self.tail(2)
        huge["queue"] = [["id": "q-1", "prompt": String(repeating: "p", count: AgentPaneTailCache.bytes + 1)]]
        #expect(Self.bridge("chat.tail", ["sessionId": "s-9", "tail": huge])["ok"] as? Bool == true,
                "the host refuses the tail, not the request")
        // Refused, and the older tail is gone: the page has read on, so what it kept is stale.
        #expect(Self.value(Self.bridge("chat.tail.get", ["sessionId": "s-9"])) is NSNull)
    }

    /// The one line no test here can reach: the pane's own host answers these ops from
    /// `AgentPaneBridge.userContentController`, and a `WKScriptMessage` cannot be made outside
    /// WebKit, so nothing can send that handler a message. Every test above calls
    /// `AgentPaneTailCache.reply` directly. Delete the handler's branch and all of them stay green
    /// while every new tab silently opens cold again — the whole point of this cache, on the host
    /// `agent.pageHost: false` makes production use. So the call site is read out of the source.
    ///
    /// Renaming either symbol is fine; this test then names what to rewrite it to.
    @Test func theHandlerStillRoutesTheseOpsToThisCache() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 6 { root.deleteLastPathComponent() }
        let bridge = root.appending(path: "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneBridge.swift")
        // Read, not guessed: a missing or unreadable file fails rather than passing vacuously.
        let source = try String(contentsOf: bridge, encoding: .utf8)
        guard let handler = source.range(of: "func userContentController(") else {
            Issue.record("AgentPaneBridge no longer has a userContentController handler")
            return
        }
        // Inside the handler, not merely somewhere in the file: the slice ends at the next doc
        // comment, which today is the one on `reply(for:)`.
        let rest = source[handler.lowerBound...]
        let body = rest.range(of: "\n    /// ").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
        // The routing AND how it decides: a `hasPrefix("chat.tail")` here would still mention the
        // type and still open the chat, while taking a later `chat.tail.forget` as a write and
        // erasing the tail. `handles(method:)` is the one that names its ops.
        #expect(body.contains("pageGeneration: generation"))
        #expect(source.contains("private let tailGeneration = AgentPaneTailCache.shared.generation"))
        #expect(body.contains("AgentPaneTailCache.handles(method:"),
                """
                AgentPaneBridge.userContentController no longer routes chat.tail to \
                AgentPaneTailCache.handles(method:), so either the ops reach AgentPaneModel, which \
                has no case for them (every chat opened in a new tab waits for acpmux again), or \
                they are matched some other way — by prefix, which erases the tail of any later \
                chat.tail.* op. Route them through handles(method:) again, or give AgentPaneModel \
                the ops and update this test.
                """)
    }
}
