@testable import CmuxNextAgentPane
import Foundation
import Testing

/// A Cloud or SSH chat's `!` command runs on the chat's machine, in its folder there (Leo,
/// cmuxterm-hq#7856: "whatever works on a local chat should work on a Cloud chat"). The pane
/// forwards run, read and stop to the machine's link; nothing runs on this Mac (cx-k21v), and a
/// run still needs the person's gesture.
@MainActor @Suite(.serialized)
struct AgentPaneRemoteChatShellTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @MainActor private final class Machine: AgentPaneMachineShell {
        var runs: [(command: String, cwd: String?, scope: String)] = []
        var reads: [(id: String, after: Int)] = []
        var stops: [String] = []
        var refusal: AgentPaneShell.Failure?

        func runShell(_ command: String, cwd: String?, scope: String) async throws -> String {
            if let refusal { throw refusal }
            runs.append((command, cwd, scope))
            return "run_\(runs.count)"
        }

        func readShell(_ id: String, after: Int) async throws -> AgentPaneShell.Chunk {
            reads.append((id, after))
            return AgentPaneShell.Chunk(output: "on the machine\n", next: after + 15, truncated: false, exit: .init(code: 0))
        }

        func stopShell(_ id: String) async { stops.append(id) }
    }

    private static let cwd = "/home/cmux/chats/project"

    private static func model(_ machine: Machine?, remote: Bool = true) -> AgentPaneModel {
        let model = AgentPaneModel(host: NoHost())
        model.remoteChat = remote
        model.handshakeCwd = cwd
        model.shell.machine = { machine }
        return model
    }

    private static func send(_ model: AgentPaneModel, _ method: String, _ params: [String: Any], click: Bool = true) async -> [String: Any] {
        if click { model.transport.gestures.record(click: true) }
        return await model.respond(to: AgentPaneRequest(body: ["method": method, "params": params]))
    }

    private static func code(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    @Test func aRemoteChatsCommandRunsReadsAndStopsOnItsMachine() async {
        let machine = Machine()
        let model = Self.model(machine)
        let started = await Self.send(model, "shell.run", ["command": "ls -la"])
        let id = (started["value"] as? [String: Any])?["id"] as? String
        #expect(id == "run_1", "\(started)")
        // No folder from the page: the chat's folder on its machine.
        #expect(machine.runs.map(\.command) == ["ls -la"])
        #expect(machine.runs.first?.cwd == Self.cwd)
        #expect(machine.runs.first?.scope == model.shell.machineScope)

        let read = await Self.send(model, "shell.read", ["id": "run_1", "after": 0], click: false)
        let result = read["value"] as? [String: Any]
        #expect(result?["output"] as? String == "on the machine\n", "\(read)")
        #expect((result?["exit"] as? [String: Any])?["code"] as? Int == 0)
        #expect(machine.reads.map(\.id) == ["run_1"])

        _ = await Self.send(model, "shell.stop", ["id": "run_1"], click: false)
        #expect(machine.stops == ["run_1"])
        #expect(model.shell.hasRuns, "closing the pane stops it on the machine")
    }

    @Test func thePagesFolderIsTheMachinesFolder() async {
        let machine = Machine()
        let model = Self.model(machine)
        _ = await Self.send(model, "shell.run", ["command": "pwd", "cwd": "/home/cmux/other"])
        #expect(machine.runs.first?.cwd == "/home/cmux/other")
    }

    @Test func aRunNeedsAGestureAndAMachine() async {
        let machine = Machine()
        let model = Self.model(machine)
        #expect(Self.code(await Self.send(model, "shell.run", ["command": "ls"], click: false)) == "shell.gesture_required")
        // A chat elsewhere with no link to its machine runs nothing anywhere.
        let unlinked = Self.model(nil)
        #expect(Self.code(await Self.send(unlinked, "shell.run", ["command": "ls"])) == "shell.failed")
        #expect(machine.runs.isEmpty)
        #expect(!unlinked.shell.hasRuns, "nothing ran on this Mac")
    }

    @Test func aMachinesRefusalIsTheSameMessageAsHere() async {
        let machine = Machine()
        machine.refusal = .tooMany
        let model = Self.model(machine)
        let reply = await Self.send(model, "shell.run", ["command": "sleep 1"])
        #expect(Self.code(reply) == "shell.failed")
        #expect((reply["error"] as? [String: Any])?["userMessage"] as? String == AgentPaneModel.shellFailureMessage(AgentPaneShell.Failure.tooMany))
    }
}
