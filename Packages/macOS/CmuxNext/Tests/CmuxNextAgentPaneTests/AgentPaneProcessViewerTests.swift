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
        let viewer = try #require(AgentPaneProcessViewer(executable: acpmux, socket: "/tmp/acpmux-501/acpmux.sock",
                                                         session: "0190a000-0000-7000-8000-0000000000e1", toolCall: "toolu_1"))
        #expect(viewer.argv == [acpmux.path, "process", "show", "--follow",
                                "--session", "0190a000-0000-7000-8000-0000000000e1", "--tool-call", "toolu_1"])
        #expect(viewer.environment == ["ACPMUX_SOCKET": "/tmp/acpmux-501/acpmux.sock"])
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
        let reply = await model.respond(to: Self.request("toolu_9"))
        #expect(reply["ok"] as? Bool == true)
        #expect((reply["value"] as? [String: Any])?["opened"] as? Bool == true)
        #expect(opened.map(\.argv) == [["/opt/acpmux", "process", "show", "--follow", "--session", "chat-1", "--tool-call", "toolu_9"]])
    }

    @Test func aLocalChatWithoutADaemonIsRefused() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat-1")
        var opened = 0
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() },
                                            openProcess: { _ in opened += 1; return true })
        #expect(await model.respond(to: Self.request("toolu_9"))["ok"] as? Bool != true, "no socket from a handshake")
        #expect(opened == 0)
    }

    /// "Whatever works on a local chat should work on a Cloud chat" (Leo, cmuxterm-hq#7856): a
    /// Cloud or SSH chat's viewer runs on its own machine and reads that machine's acpmux.
    @Test func aChatOnAnotherMachineOpensTheViewerOnThatMachine() async throws {
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat-1")
        var opened: [AgentPaneProcessViewer] = []
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() },
                                            openProcess: { opened.append($0); return true })
        model.remoteChat = true
        let reply = await model.respond(to: Self.request("toolu_9"))
        #expect((reply["value"] as? [String: Any])?["opened"] as? Bool == true)
        let viewer = try #require(opened.first)
        #expect(viewer.onChatMachine)
        #expect(viewer.environment.isEmpty, "this Mac's acpmux socket never reaches the other machine")
        #expect(viewer.argv.first == "/bin/sh")
        #expect(viewer.argv.suffix(2) == ["chat-1", "toolu_9"], "the ids are the script's arguments")
        #expect(viewer.argv[2].contains(#"acp process show --follow --session "$1" --tool-call "$2""#))
        #expect(!viewer.argv[2].contains("chat-1") && !viewer.argv[2].contains("toolu_9"))
        #expect(AgentPaneProcessViewer(onChatMachine: "chat-1", toolCall: "$(reboot)") == nil)
    }
}

/// A chat an added ssh machine runs, reached through this Mac's acpmux: the header's Terminal posts
/// `chat.machineTerminal {machine, cwd}` and the pane asks the App to open `acpmux machine shell`
/// beside the chat (Leo, 2026-11-06: "the terminal I open on the top right button works thru that machine").
@Suite
@MainActor
struct AgentPaneMachineShellTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    static func request(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "chat.machineTerminal", "params": params])
    }

    @Test func theRequestNamesAPlainMachine() {
        #expect(Self.request(["machine": "box", "cwd": "/home/leo/repo"]) == .machineTerminal(machine: "box", cwd: "/home/leo/repo"))
        #expect(Self.request(["machine": "box", "cwd": ""]) == .machineTerminal(machine: "box", cwd: nil))
        #expect(Self.request(["machine": "eval box"]) == .machineTerminal(machine: "eval box", cwd: nil), "a name with a space")
        #expect(Self.request(["machine": "-oProxyCommand=x"]) == .unsupported("chat.machineTerminal"))
        #expect(Self.request(["machine": "box\nx"]) == .unsupported("chat.machineTerminal"))
        #expect(Self.request([:]) == .unsupported("chat.machineTerminal"))
    }

    @Test func theTerminalRunsTheMachinesShellInTheChatsFolder() async throws {
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat-1")
        var opened: [AgentPaneProcessViewer] = []
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() },
                                            openProcess: { opened.append($0); return true })
        model.transport.acpmuxSocket = "/tmp/acpmux.sock"
        model.transport.acpmuxExecutable = URL(fileURLWithPath: "/opt/acpmux")
        // New Agent Chat on a peer marks the page remote (its handshake names the peer): it still opens.
        model.remoteChat = true
        let reply = await model.respond(to: Self.request(["machine": "box", "cwd": "-rf it's"]))
        #expect((reply["value"] as? [String: Any])?["opened"] as? Bool == true)
        let viewer = try #require(opened.first)
        #expect(viewer.argv == ["/opt/acpmux", "machine", "shell", "box", "--cwd=-rf it's"], "the folder is one argument, never an option")
        #expect(viewer.environment == ["ACPMUX_SOCKET": "/tmp/acpmux.sock"])
        #expect(!viewer.onChatMachine, "the shell's terminal is this Mac's, beside the chat")
    }

    @Test func aChatWithItsOwnMachineDaemonIsRefused() async {
        // A Cloud or SSH chat's page talks to that machine's acpmux: the handshake leaves no socket here.
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat-1")
        var opened = 0
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() },
                                            openProcess: { _ in opened += 1; return true })
        model.remoteChat = true
        #expect(await model.respond(to: Self.request(["machine": "box"]))["ok"] as? Bool != true, "no acpmux socket here")
        #expect(opened == 0)
    }
}
