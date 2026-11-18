import CmuxMobileAgentChat
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Leo, 2026-11-18, on an iPhone "New chat" that said "Agent hasn't started in this tab. Send the
/// first message from cmux on cosmic-gray; the chat continues here.": "This is pretty weird.
/// Like, you should be able to just start the chat right there. Why is this dialogue showing?"
///
/// A chat tab with no session opens as an empty new chat with no notice, and its first message
/// starts it from the phone (`NewChatAgentSource`: the session `start` makes, then that prompt).
@MainActor
@Suite struct NewChatStartsFromPhoneTests {
    final class Mac: @unchecked Sendable {
        private let lock = NSLock()
        private var _prompts: [String] = []
        var prompts: [String] { lock.withLock { _prompts } }
        func prompted(_ text: String) { lock.withLock { _prompts.append(text) } }
    }

    nonisolated static func link(_ mac: Mac) -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize":
                return [reply(#"{"protocolVersion":1,"_meta":{"acpmux":{"fullAccess":true}}}"#)]
            case "_acpmux/watch":
                return [reply(#"{"sessions":[{"sessionId":"s-new","name":"New chat","harness":"claude","cwd":"/tmp/w","status":"idle"}]}"#)]
            case "_acpmux/attach":
                return [reply(#"{"session":{"sessionId":"s-new","status":"idle","pending":[]},"hasMore":false,"lastSeq":0,"events":[]}"#)]
            case "session/prompt":
                let params = object["params"] as? [String: Any]
                mac.prompted(((params?["prompt"] as? [[String: Any]])?.first?["text"] as? String) ?? "")
                return [reply(#"{"stopReason":"end_turn"}"#)]
            default:
                return [reply("{}")]
            }
        }
    }

    static let summary = AgentSessionSummary(id: "s12", name: "New chat", harness: "claude", agentName: "Claude",
                                             cwd: "/tmp/w", workspaceTitle: "claude-sr2-coord", macName: "cosmic-gray")

    func settle(_ until: () -> Bool) async {
        for _ in 0..<2000 where !until() { await Task.yield() }
    }

    @Test func aNewChatOpensWithNoNoticeAndItsFirstMessageStartsIt() async throws {
        let mac = Mac()
        let link = Self.link(mac)
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        defer { withExtendedLifetime(hub) {} }
        var starts = 0
        let source = NewChatAgentSource(summary: Self.summary) {
            starts += 1
            return hub.source(sessionID: "s-new", summary: Self.summary)
        }
        let store = AgentChatStore(source: source)
        for _ in 0..<200 { await Task.yield() }
        #expect(store.clientError == nil, "a new chat says nothing about having started")

        store.send(prompt: "fix the flaky test")
        await settle { mac.prompts.count == 1 }
        #expect(starts == 1)
        #expect(mac.prompts == ["fix the flaky test"], "the first message goes to the session it started")
        #expect(store.clientError == nil)
        #expect(store.returnedDraft == nil)
    }

    @Test func aStartThatFailsBringsTheDraftBackWithTheMacsReason() async throws {
        let source = NewChatAgentSource(summary: Self.summary) {
            throw WorkspaceCreationError("Trust w in cmux on the Mac to start agent chats there.", isForPerson: true)
        }
        let store = AgentChatStore(source: source)
        for _ in 0..<200 { await Task.yield() }
        store.send(prompt: "hello")
        await settle { store.returnedDraft != nil }
        #expect(store.returnedDraft?.text == "hello", "the message is not lost")
        #expect(store.clientError?.contains("hasn't started") != true)
    }
}
