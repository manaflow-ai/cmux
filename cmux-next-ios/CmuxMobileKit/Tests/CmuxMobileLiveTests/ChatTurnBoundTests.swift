import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Leo, 2026-11-24: "I feel like there are often these like dead hang loops ... endless freezes,
/// these soft locks if not hard locks". Each chat wait here has a bound and a way out:
/// a prompt whose reply never comes, a Stop the Mac doesn't confirm, a chat that never loads.
@MainActor
@Suite struct ChatTurnBoundTests {
    /// The fake acpmux: answers what each test sets, never a `session/prompt`.
    final class Mac: @unchecked Sendable {
        private let lock = NSLock()
        private var _status = "running"
        private var _answersInfo = true
        private var _answersCancel = true
        private var _attachFails = false
        private var _cancels = 0
        private var _attaches = 0
        var status: String { get { lock.withLock { _status } } set { lock.withLock { _status = newValue } } }
        var answersInfo: Bool { get { lock.withLock { _answersInfo } } set { lock.withLock { _answersInfo = newValue } } }
        var answersCancel: Bool { get { lock.withLock { _answersCancel } } set { lock.withLock { _answersCancel = newValue } } }
        var attachFails: Bool { get { lock.withLock { _attachFails } } set { lock.withLock { _attachFails = newValue } } }
        var cancels: Int { lock.withLock { _cancels } }
        var attaches: Int { lock.withLock { _attaches } }
        func cancelled() { lock.withLock { _cancels += 1 } }
        func attached() { lock.withLock { _attaches += 1 } }
    }

    nonisolated static func link(_ mac: Mac) -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize":
                return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch":
                return [reply(#"{"sessions":[{"sessionId":"s1","name":"lane","harness":"claude","cwd":"/tmp/w","status":"running"}]}"#)]
            case "_acpmux/attach":
                mac.attached()
                if mac.attachFails {
                    return [Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"busy"}}"#.utf8)]
                }
                return [reply(#"{"session":{"sessionId":"s1","status":"running","pending":[]},"hasMore":false,"lastSeq":0,"events":[]}"#)]
            case "_acpmux/info":
                guard mac.answersInfo else { return [] }
                return [reply(#"{"sessionId":"s1","status":"\#(mac.status)","lastSeq":0}"#)]
            case "session/prompt":
                return [] // the reply that never comes
            case "session/cancel":
                mac.cancelled()
                return mac.answersCancel ? [reply("{}")] : []
            default:
                return [reply("{}")]
            }
        }
    }

    static let summary = AgentSessionSummary(id: "s1", name: "lane", harness: "claude", agentName: "Claude",
                                             cwd: "/tmp/w", workspaceTitle: "w", macName: "mini")
    static let promptParams: JSONValue = .object([
        "sessionId": .string("s1"), "prompt": .array([.object(["type": .string("text"), "text": .string("go")])]),
    ])

    func boundHub(_ mac: Mac) async throws -> (AcpmuxHub, MockMacLink) {
        let link = Self.link(mac)
        let hub = AcpmuxHub()
        hub.promptSilence = .milliseconds(100)
        hub.stallAfter = .milliseconds(200)
        hub.stopBound = .milliseconds(100)
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        #expect(hub.isReady)
        return (hub, link)
    }

    /// Whether `body` finishes within `bound` (real time), and how long it took.
    func finishes(within bound: Duration, _ body: @escaping @MainActor () async -> Void) async -> Duration? {
        let start = ContinuousClock.now
        let done = Task { @MainActor in await body(); return ContinuousClock.now - start }
        let timer = Task { try? await Task.sleep(for: bound); done.cancel() }
        defer { timer.cancel() }
        let took = await done.value
        return took < bound ? took : nil
    }

    func settle(_ until: () -> Bool) async {
        for _ in 0..<4000 where !until() {
            await Task.yield()
            if !until() { try? await Task.sleep(for: .milliseconds(1)) }
        }
    }

    /// The turn ended on the Mac but its reply never came: before, the prompt waited 24 h (its
    /// write stayed "in flight", which also kept every stall on the channel from recovering).
    @Test func aPromptWhoseTurnEndedUnansweredStopsWaiting() async throws {
        let mac = Mac()
        mac.status = "idle"
        let (hub, _) = try await boundHub(mac)
        defer { withExtendedLifetime(hub) {} }
        let took = await finishes(within: .seconds(5)) { _ = try? await hub.prompt(Self.promptParams) }
        #expect(took != nil, "the wait ends after its silence bound once the Mac says the turn is over")
        #expect(await hub.connection?.hasWritesInFlight == false)
    }

    /// The Mac stopped answering altogether: the channel is recovered and the prompt's wait fails
    /// as closed (a chat holds and resends it; acpmux runs it at most once).
    @Test func aSilentPromptOnADeadChannelRecoversIt() async throws {
        let mac = Mac()
        mac.answersInfo = false
        let (hub, link) = try await boundHub(mac)
        defer { withExtendedLifetime(hub) {} }
        var recovered = 0
        hub.onStall = { @MainActor in
            recovered += 1
            mac.answersInfo = true
            await hub.bind(try? await link.openChannel(service: "acpmux", args: [:]))
        }
        var failed = false
        let took = await finishes(within: .seconds(5)) {
            do { _ = try await hub.prompt(Self.promptParams) } catch { failed = true }
        }
        #expect(took != nil)
        #expect(failed)
        #expect(recovered == 1)
    }

    /// A long turn (the Mac says it runs) is waited for, however long: silence alone ends nothing.
    @Test func aRunningTurnIsWaitedFor() async throws {
        let mac = Mac()
        let (hub, _) = try await boundHub(mac)
        defer { withExtendedLifetime(hub) {} }
        let took = await finishes(within: .milliseconds(600)) { _ = try? await hub.prompt(Self.promptParams) }
        #expect(took == nil, "still waiting after several silence bounds")
    }

    /// Stop is confirmed: a turn still running past the bound says so, with Stop again.
    @Test func aStopTheTurnIgnoresSaysSoWithStopAgain() async throws {
        let mac = Mac()
        let (hub, _) = try await boundHub(mac)
        defer { withExtendedLifetime(hub) {} }
        let source = hub.source(sessionID: "s1", summary: Self.summary)
        let store = AgentChatStore(source: source)
        for _ in 0..<200 { await Task.yield() }
        store.cancel()
        await settle { store.clientErrorAction != nil }
        #expect(store.clientError == "Claude is still running on mini.")
        #expect(store.clientErrorAction?.title == "Stop again")
        #expect(mac.cancels == 1)
        store.takeClientErrorAction()
        await settle { mac.cancels == 2 }
        #expect(mac.cancels == 2, "the action stops again")
    }

    /// A Stop the Mac never answers: before, nothing was said (a notification has no answer).
    @Test func anUnconfirmedStopSaysSo() async throws {
        let mac = Mac()
        mac.answersCancel = false
        let (hub, _) = try await boundHub(mac)
        defer { withExtendedLifetime(hub) {} }
        let source = hub.source(sessionID: "s1", summary: Self.summary)
        let store = AgentChatStore(source: source)
        for _ in 0..<200 { await Task.yield() }
        store.cancel()
        await settle { store.clientErrorAction != nil }
        #expect(store.clientError == "mini didn't confirm the stop.")
        #expect(store.clientErrorAction?.title == "Stop again")
    }

    /// A stop that ends the turn says nothing.
    @Test func aStopThatEndsTheTurnSaysNothing() async throws {
        let mac = Mac()
        let (hub, _) = try await boundHub(mac)
        defer { withExtendedLifetime(hub) {} }
        let source = hub.source(sessionID: "s1", summary: Self.summary)
        let store = AgentChatStore(source: source)
        for _ in 0..<200 { await Task.yield() }
        mac.status = "idle"
        store.cancel()
        try await Task.sleep(for: .milliseconds(500)) // test: past the shortened stop bound
        #expect(store.clientError == nil)
    }

    /// A chat whose attach keeps failing on a link that stays up stops trying, says so, and
    /// Try again loads it. Before, it retried every 15 s for as long as the chat was open.
    @Test func aChatThatNeverLoadsStopsWithTryAgain() async throws {
        let mac = Mac()
        mac.attachFails = true
        let (hub, _) = try await boundHub(mac)
        defer { withExtendedLifetime(hub) {} }
        let source = hub.source(sessionID: "s1", summary: Self.summary)
        source.attachBackoff = { _ in .milliseconds(5) }
        let store = AgentChatStore(source: source)
        await settle { store.clientErrorAction != nil }
        #expect(store.clientError == "Couldn't load this chat from mini.")
        #expect(store.clientErrorAction?.title == "Try again")
        let tries = mac.attaches
        #expect(tries == AcpmuxSessionSource.maxAttachFailures)
        try await Task.sleep(for: .milliseconds(100))
        #expect(mac.attaches == tries, "no more tries until Try again")

        mac.attachFails = false
        store.takeClientErrorAction()
        await settle { mac.attaches > tries && store.clientError == nil }
        #expect(mac.attaches == tries + 1)
        #expect(store.clientError == nil)
    }
}
