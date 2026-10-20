import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A background task's terminal at the pane boundary (background-task-terminal-DESIGN.md): a click
/// on a background task row posts `chat.processTerminal {toolCallId}`; the pane asks the App to
/// open `acpmux process show --follow` for that chat's tool call beside the chat, with the chat's
/// own acpmux, and refuses what it cannot vouch for.
@Suite
@MainActor
struct AgentPaneProcessViewerTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    static func request(_ toolCall: Any) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "chat.processTerminal", "params": ["toolCallId": toolCall]])
    }

    @Test func theRequestNamesTheToolCall() {
        #expect(Self.request("toolu_01AbC") == .processTerminal(toolCall: "toolu_01AbC"))
        #expect(Self.request("") == .unsupported("chat.processTerminal"))
        #expect(Self.request("--help") == .unsupported("chat.processTerminal"), "an id that reads as an option")
        #expect(Self.request("a b") == .unsupported("chat.processTerminal"))
        #expect(Self.request(7) == .unsupported("chat.processTerminal"))
    }

    @Test func theViewerRunsAcpmuxProcessShowForTheChatsToolCall() throws {
        let acpmux = URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/bin/acpmux")
        let socket = "/tmp/acpmux-501/acpmux.sock"
        let session = "0190a000-0000-7000-8000-0000000000e1"
        let toolCall = "toolu_1"
        let key = AcpmuxPersonKey.spawnKey(for: socket)
        let viewer = try #require(AgentPaneProcessViewer(executable: acpmux, socket: socket,
                                                         session: session, toolCall: toolCall))
        #expect(viewer.argv == [acpmux.path, "process", "show", "--follow",
                                "--session", session, "--tool-call", toolCall])
        #expect(viewer.environment["ACPMUX_SOCKET"] == socket)
        #expect(viewer.environment["ACPMUX_PROCESS_VIEWER_SOCKET"] == socket)
        #expect(viewer.environment["ACPMUX_PROCESS_VIEWER_SESSION"] == session)
        #expect(viewer.environment["ACPMUX_PROCESS_VIEWER_TOOL_CALL"] == toolCall)
        let nonce = try #require(viewer.environment["ACPMUX_PROCESS_VIEWER_NONCE"])
        let proof = try #require(viewer.environment["ACPMUX_PROCESS_VIEWER_PROOF"])
        #expect(nonce.utf8.count == 64)
        #expect(proof == AcpmuxPersonKey.processViewerProof(key: key, session: session, toolCall: toolCall, nonce: nonce))
        #expect(!viewer.title.isEmpty)
        #expect(AgentPaneProcessViewer(executable: acpmux, socket: "", session: "s", toolCall: "t") == nil)
    }

    @Test func aClickOpensTheViewerBesideTheChat() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat-1")
        var opened: [AgentPaneProcessViewer] = []
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() },
                                            openProcess: { opened.append($0); return true })
        model.transport.acpmuxSocket = "/tmp/acpmux.sock"
        model.transport.acpmuxExecutable = URL(fileURLWithPath: "/opt/acpmux")
        _ = AcpmuxPersonKey.spawnKey(for: "/tmp/acpmux.sock")
        let reply = await model.respond(to: Self.request("toolu_9"))
        #expect(reply["ok"] as? Bool == true)
        #expect((reply["value"] as? [String: Any])?["opened"] as? Bool == true)
        #expect(opened.map(\.argv) == [["/opt/acpmux", "process", "show", "--follow", "--session", "chat-1", "--tool-call", "toolu_9"]])
    }

    @Test func aChatOnAnotherMachineOrWithoutADaemonIsRefused() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat-1")
        var opened = 0
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() },
                                            openProcess: { _ in opened += 1; return true })
        #expect(await model.respond(to: Self.request("toolu_9"))["ok"] as? Bool != true, "no socket from a handshake")
        model.transport.acpmuxSocket = "/tmp/acpmux.sock"
        model.transport.acpmuxExecutable = URL(fileURLWithPath: "/opt/acpmux")
        model.remoteChat = true
        #expect(await model.respond(to: Self.request("toolu_9"))["ok"] as? Bool != true, "another machine's chat")
        #expect(opened == 0)
    }
}
