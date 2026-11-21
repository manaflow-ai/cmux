import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Leo on LTE, 2026-11-12: "thjs chatters too often with connectivity". A chat message sent
/// while the link is down for a moment waits for it, as the terminal's keys do, and goes once
/// the link is back: in order, each once, with no notice. Only a real outage (past the
/// window) brings the draft back with what happened. And the "Full access is off" notice is
/// the Mac's word on what the message needs, never a reconnect's: it goes once a connection
/// says Full access covers the phone.
@MainActor
@Suite struct ChatPromptBlipTests {
    /// The fake acpmux: the prompts it got (text, promptId, resend), and whether this phone's
    /// Full-access setting covers a message to the chat (it runs in Bypass permissions).
    final class Mac: @unchecked Sendable {
        private let lock = NSLock()
        private var _prompts: [(text: String, promptID: String, resend: Bool)] = []
        private var _fullAccess: Bool
        init(fullAccess: Bool = true) { _fullAccess = fullAccess }
        var fullAccess: Bool {
            get { lock.withLock { _fullAccess } }
            set { lock.withLock { _fullAccess = newValue } }
        }
        var prompts: [(text: String, promptID: String, resend: Bool)] { lock.withLock { _prompts } }
        func prompted(_ text: String, _ id: String, _ resend: Bool) { lock.withLock { _prompts.append((text, id, resend)) } }
    }

    nonisolated static func link(_ mac: Mac) -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize":
                return [reply(#"{"protocolVersion":1,"_meta":{"acpmux":{"fullAccess":\#(mac.fullAccess)}}}"#)]
            case "_acpmux/watch":
                return [reply(#"{"sessions":[{"sessionId":"s1","name":"lane","harness":"claude","cwd":"/tmp/w","status":"running"}]}"#)]
            case "_acpmux/attach":
                return [reply(#"{"session":{"sessionId":"s1","status":"running","pending":[]},"hasMore":false,"lastSeq":0,"events":[]}"#)]
            case "session/prompt":
                let params = object["params"] as? [String: Any]
                let text = ((params?["prompt"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                let meta = (params?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
                // The mobile host marks a message to a chat that does not ask requireFullAccess;
                // acpmux refuses it when the setting does not cover the phone (remote_guard.rs).
                if !mac.fullAccess {
                    return [Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"Full access is off for this device: turn it on for this device in Settings > Devices on the Mac","data":{"reason":"remote.full_access_required"}}}"#.utf8)]
                }
                mac.prompted(text, meta?["promptId"] as? String ?? "", meta?["resend"] as? Bool ?? false)
                return [reply(#"{"stopReason":"end_turn"}"#)]
            default:
                return [reply("{}")]
            }
        }
    }

    static let summary = AgentSessionSummary(id: "s1", name: "lane", harness: "claude", agentName: "Claude",
                                             cwd: "/tmp/w", workspaceTitle: "w", macName: "mini")

    func openChat(_ mac: Mac) async throws -> (AcpmuxHub, MockMacLink, AcpmuxSessionSource, AgentChatStore) {
        let link = Self.link(mac)
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        #expect(hub.isReady)
        let source = hub.source(sessionID: "s1", summary: Self.summary)
        let store = AgentChatStore(source: source)
        for _ in 0..<200 { await Task.yield() }
        return (hub, link, source, store)
    }

    func settle(_ until: () -> Bool) async {
        for _ in 0..<2000 where !until() { await Task.yield() }
    }

    @Test func messagesSentDuringABlipGoInOrderOnceTheLinkIsBack() async throws {
        let mac = Mac()
        let (hub, link, source, store) = try await openChat(mac)
        defer { withExtendedLifetime(hub) {} }
        await hub.bind(nil) // the link drops
        store.send(prompt: "first")
        store.send(prompt: "second")
        await settle { source.heldPrompts.count == 2 }
        #expect(source.heldPrompts.map(\.text) == ["first", "second"])
        #expect(store.clientError == nil, "a blip says nothing")
        #expect(store.returnedDraft == nil)

        await hub.bind(try await link.openChannel(service: "acpmux", args: [:])) // back within the window
        await settle { mac.prompts.count == 2 }
        for _ in 0..<100 { await Task.yield() }
        #expect(mac.prompts.map(\.text) == ["first", "second"], "in order, each once")
        #expect(Set(mac.prompts.map(\.promptID)).count == 2)
        #expect(source.heldPrompts.isEmpty)
        #expect(store.clientError == nil)
        #expect(store.returnedDraft == nil)
    }

    @Test func aMessageHeldPastTheWindowComesBackWithWhatHappened() async throws {
        let mac = Mac()
        let (hub, link, source, store) = try await openChat(mac)
        defer { withExtendedLifetime(hub) {} }
        source.heldPromptWindow = .milliseconds(50)
        await hub.bind(nil)
        store.send(prompt: "run the tests")
        try await Task.sleep(for: .milliseconds(150)) // test: past the shortened window
        await settle { store.returnedDraft != nil }
        #expect(store.returnedDraft?.text == "run the tests")
        #expect(store.clientError?.hasPrefix("Not sent: mini was unreachable for more than") == true)
        #expect(source.heldPrompts.isEmpty)

        // The Mac comes back later: the stale message is not sent behind the person's back.
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        for _ in 0..<300 { await Task.yield() }
        #expect(mac.prompts.isEmpty)
    }

    /// Leo's lanes run in Bypass permissions, and his phone's Full-access setting was off: a
    /// message to one is refused, truly. The draft comes back with what to change; a reconnect
    /// alone shows nothing, and a connection that says Full access is on clears the notice.
    @Test func fullAccessNoticeIsTheMacsWordAndClearsOnReconnectWithAccess() async throws {
        let mac = Mac(fullAccess: false)
        let (hub, link, _, store) = try await openChat(mac)
        defer { withExtendedLifetime(hub) {} }
        // A reconnect by itself never shows it.
        await hub.bind(nil)
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        for _ in 0..<300 { await Task.yield() }
        #expect(store.clientError == nil)

        store.send(prompt: "keep going")
        await settle { store.clientError != nil }
        #expect(store.clientError == AgentChatStore.fullAccessOffPromptNotice)
        #expect(store.returnedDraft?.text == "keep going", "the message is not lost")
        #expect(mac.prompts.isEmpty)

        // Turned on on the Mac: the next connection says so, and the notice goes.
        mac.fullAccess = true
        await hub.bind(nil)
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        await settle { store.clientError == nil }
        #expect(store.clientError == nil)
    }
}
