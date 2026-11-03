import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A new chat on another machine starts on the model the page showed (webviews direct.ts
/// `newSessionParams`, `_meta.acpmux.model`; acpmux reads it as the start model). The relay's
/// params rule did not list `model` for `session/new`, so it refused the start
/// (`transport.intent_invalid`) and no chat started on that machine. At the relay boundary (the
/// page's frames into ``AgentPaneTransport``, out to acpmux): the model goes through as one model
/// id, and every other `_meta.acpmux` key the pane never sends is still refused.
@Suite(.serialized)
@MainActor
struct AgentPaneNewChatModelRelayTests {
    static func start(id: Int, acpmux: String, cwd: String = "/a") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"session/new","params":{"cwd":"\#(cwd)","mcpServers":[],"_meta":{"acpmux":{\#(acpmux)}}}}"#
    }

    static func object(_ frame: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) as? [String: Any]
    }

    static func breaks(_ acpmux: String) -> Bool {
        AcpmuxPaneMethods.breaksParamsRule(object(start(id: 1, acpmux: acpmux)), modeFields: [])
    }

    @Test func theStartOnAnotherMachineMayNameItsModel() {
        for model in ["claude-opus-5-5", "gpt-6-astra", "openrouter/meta-llama/llama-4:free", "claude-opus-5-5[1m]",
                      "claude-3-7@20250219", "anthropic.claude-v2:1", "g" + String(repeating: "x", count: 255)] {
            #expect(!Self.breaks(#""harness":"claude","peer":"devbox","model":"\#(model)""#), "\(model)")
        }
        // The page's other starts are unchanged.
        #expect(!Self.breaks(#""harness":"claude","peer":"devbox""#))
        #expect(!Self.breaks(#""harness":"claude","noProject":true"#))
    }

    @Test func aModelThatIsNotOneModelIdIsRefused() {
        // Not a string, empty, a flag, whitespace, a control character, shell or template text, too long.
        for model in ["1", "null", "true", #"["m"]"#, #"{"id":"m"}"#, #""""#, #""-p""#, #""--dangerously-skip-permissions""#,
                      #""a b""#, #""a\tb""#, #""a\nb""#, #""a\u0000""#, #""${HOME}""#, #""$(id)""#, #""m;rm""#, #""m|x""#,
                      #""m`x`""#, #""m'x""#, #""m\"x""#, #""m\\x""#, #""é""#, #""\#(String(repeating: "x", count: 257))""#] {
            #expect(Self.breaks(#""harness":"claude","peer":"devbox","model":\#(model)"#), "\(model)")
        }
    }

    @Test func everyOtherAcpmuxKeyIsStillRefused() {
        // Control, trust-gate, policy and identity keys acpmux reads from a start's `_meta.acpmux`.
        for key in ["effort", "preset", "policy", "route", "name", "env", "workspaceId", "resend", "control",
                    "fullAccess", "parent", "toolCallId", "disallowedTools", "worktree", "ephemeral", "localAppToken",
                    "forwarded", "trust", "models", "modelId"] {
            #expect(Self.breaks(#""harness":"claude","peer":"devbox","model":"m","\#(key)":"x""#), "\(key)")
        }
        // `model` is a start's `_meta.acpmux` key only: never a top-level param, nor on another method.
        let top = #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/a","model":"m"}}"#
        #expect(AcpmuxPaneMethods.breaksParamsRule(Self.object(top), modeFields: []))
        let prompt = #"{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"sessionId":"s","prompt":[],"_meta":{"acpmux":{"promptId":"p","model":"m"}}}}"#
        #expect(AcpmuxPaneMethods.breaksParamsRule(Self.object(prompt), modeFields: []))
        // `_meta` holds only `acpmux`.
        let other = #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"_meta":{"acpmux":{"model":"m"},"model":"m"}}}"#
        #expect(AcpmuxPaneMethods.breaksParamsRule(Self.object(other), modeFields: []))
    }

    @Test(.timeLimit(.minutes(1))) func theStartReachesAcpmuxWithTheModel() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("new-chat-model-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        transport.roots = { [folder] }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        let starts = { server.peers.first?.frames.filter { $0.contains("session/new") } ?? [] }

        #expect(await transport.send(connection: id, frames: [Self.start(id: 1, acpmux: #""harness":"claude","peer":"devbox","model":"m","policy":"bypass""#, cwd: folder)])
                == .intentInvalid, "a key the pane never sends")
        #expect(await transport.send(connection: id, frames: [Self.start(id: 2, acpmux: #""harness":"claude","peer":"devbox","model":"-p""#, cwd: folder)])
                == .intentInvalid, "a model that is a flag")
        #expect(starts().isEmpty, "a refused start reached acpmux: \(starts())")

        // The person's send on the New Tab with another machine picked.
        transport.gestures.record()
        let sent = await transport.send(connection: id, frames: [Self.start(id: 3, acpmux: #""harness":"claude","peer":"devbox","model":"claude-opus-5-5""#, cwd: folder)])
        #expect(sent == nil, "the relay refused the start on another machine with its model")
        guard sent == nil else { return }
        _ = await inbox.frame(containing: #""id":3"#)
        let acpmux = try #require(starts().first.flatMap(Self.object).flatMap { (($0["params"] as? [String: Any])?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any] })
        #expect(acpmux["model"] as? String == "claude-opus-5-5")
        #expect(acpmux["peer"] as? String == "devbox")
    }
}
