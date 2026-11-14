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

    /// A remote chat reaches only its machine's runs: an id it did not start there, even one of a
    /// command running on this Mac, is refused, and the command here keeps running.
    @Test func aRemoteChatCannotReadOrStopACommandOfThisMac() async throws {
        let machine = Machine()
        let model = Self.model(machine, remote: false)
        let started = await Self.send(model, "shell.run", ["command": "sleep 1; echo local", "cwd": NSTemporaryDirectory()])
        let local = try #require((started["value"] as? [String: Any])?["id"] as? String, "\(started)")
        model.remoteChat = true

        let read = await Self.send(model, "shell.read", ["id": local, "after": 0], click: false)
        #expect(Self.code(read) == "shell.failed", "\(read)")
        #expect((read["error"] as? [String: Any])?["userMessage"] as? String == AgentPaneModel.shellFailureMessage(AgentPaneShell.Failure.unknownRun))
        let stop = await Self.send(model, "shell.stop", ["id": local], click: false)
        #expect(Self.code(stop) == "shell.failed", "\(stop)")
        let unknown = await Self.send(model, "shell.read", ["id": "run_unknown", "after": 0], click: false)
        #expect(Self.code(unknown) == "shell.failed")
        #expect(Self.code(await Self.send(model, "shell.stop", ["id": "run_unknown"], click: false)) == "shell.failed")
        #expect(machine.reads.isEmpty && machine.stops.isEmpty, "an unknown id is not sent to the machine either")

        // The command on this Mac was not stopped: it ends on its own, with its output.
        model.remoteChat = false
        var after = 0
        var output = ""
        var exit: [String: Any]?
        for _ in 0..<20 where exit == nil {
            let chunk = try #require(await Self.send(model, "shell.read", ["id": local, "after": after], click: false)["value"] as? [String: Any])
            output += chunk["output"] as? String ?? ""
            after = chunk["next"] as? Int ?? after
            exit = chunk["exit"] as? [String: Any]
        }
        #expect(exit?["code"] as? Int == 0, "\(String(describing: exit))")
        #expect(exit?["signal"] == nil)
        #expect(output.contains("local"))
        model.shell.terminateAll()
    }

    /// A chat of this Mac never reaches a run on a machine, even one this pane started there.
    @Test func aLocalChatCannotReadOrStopAMachinesCommand() async {
        let machine = Machine()
        let model = Self.model(machine)
        let started = await Self.send(model, "shell.run", ["command": "sleep 60"])
        let id = (started["value"] as? [String: Any])?["id"] as? String
        #expect(id == "run_1", "\(started)")
        model.remoteChat = false

        let read = await Self.send(model, "shell.read", ["id": "run_1", "after": 0], click: false)
        #expect(Self.code(read) == "shell.failed", "\(read)")
        _ = await Self.send(model, "shell.stop", ["id": "run_1"], click: false)
        #expect(machine.reads.isEmpty)
        #expect(machine.stops.isEmpty)
        #expect(model.shell.machineShell(of: "run_1") != nil, "the machine's run is still the remote chat's")
    }

    private static func settle(_ machine: Machine, stops count: Int) async {
        for _ in 0..<200 where machine.stops.count < count { await Task.yield() }
    }

    @Test func aRunningCommandKeepsItsMachinePastSixteenFinishedOnes() async {
        let machine = Machine()
        let shell = Self.model(machine).shell
        shell.noteMachineRun("long", on: machine)
        for index in 0..<AgentPaneShell.maximumKept {
            shell.noteMachineRun("short_\(index)", on: machine)
            shell.noteMachineExit("short_\(index)")
        }
        #expect(shell.machineShell(of: "long") != nil, "reads and Stop still reach the running command")
        shell.terminateAll()
        await Self.settle(machine, stops: 1)
        #expect(machine.stops == ["long"], "closing the pane stops what still runs, and only that")
    }

    @Test func aStartThatAnswersAfterThePaneClosedIsStopped() async {
        let machine = Machine()
        let shell = Self.model(machine).shell
        shell.terminateAll()
        shell.noteMachineRun("late", on: machine)
        await Self.settle(machine, stops: 1)
        #expect(machine.stops == ["late"])
        #expect(shell.machineShell(of: "late") == nil)
    }
}
