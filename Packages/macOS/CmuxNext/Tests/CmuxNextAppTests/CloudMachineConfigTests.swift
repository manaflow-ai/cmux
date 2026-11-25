import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextWakeups
import Foundation
import Testing

/// `.cmux/machine.toml` (CloudMachineConfig): an apply uploads the file, its request and the applier over
/// the file API, then starts it with one short exec. A reapply with no file uploads none and lets the
/// machine pick its source. The applier, its commands and their order are cmux-cloud-start-core's
/// (`machine_config`, with their tests); these check the app's side.
@MainActor @Suite
struct CloudMachineConfigTests {
    nonisolated final class Recorder: @unchecked Sendable {
        var writes: [(path: String, data: Data, mode: Int)] = []
        var commands: [String] = []
        var startAnswer = CloudExecResult(exitCode: 0, stdout: "started\n", stderr: "")

        var machine: CloudMachineBootstrap.Machine {
            CloudMachineBootstrap.Machine(
                write: { self.writes.append(($0, $1, $2)) },
                exec: { command in
                    self.commands.append(command)
                    return command.contains("echo started") ? self.startAnswer : CloudExecResult(exitCode: 0, stdout: "", stderr: "")
                })
        }
    }

    static let toml = Data("version = 1\n[env]\nNODE_ENV = \"development\"\n[secrets]\nnames = [\"DATABASE_URL\"]\n[setup]\nrun = [\"bun install\"]\n".utf8)

    @Test func machineConfigIsAnOptionOfNewMachine() throws {
        let request = try CloudHandlers.newMachineRequest(ActionInvocation(arguments: ["machineConfig": .string("~/app/.cmux/machine.toml")], origin: .cli))
        #expect(!request.isDefault, "a config alone takes the options path")
        #expect(request.machineConfigPath == NSHomeDirectory() + "/app/.cmux/machine.toml")
        #expect(throws: ActionFailure.self) { try CloudHandlers.newMachineRequest(ActionInvocation(arguments: ["machineConfig": .string("")], origin: .cli)) }
        #expect(throws: ActionFailure.self, "a bare --machine-config arrives as true") {
            try CloudHandlers.newMachineRequest(ActionInvocation(arguments: ["machineConfig": .bool(true)], origin: .cli))
        }
    }

    @Test func anApplyStagesItsRequestBesideTheApplierThenStartsIt() async {
        let recorder = Recorder()
        let outcome = await CloudMachineConfig(contents: Self.toml).apply(on: recorder.machine, now: Date(timeIntervalSince1970: 1_792_000_000))
        #expect(outcome == CloudMachineBootstrap.Outcome(status: "started"))
        let directory = "/home/cmux/.cmux/machine-config"
        let paths = recorder.writes.map(\.path)
        #expect(paths.count == 3)
        #expect(paths.allSatisfy { $0.hasPrefix("\(directory)/requests/1792000000000-") }, "every file is this request's own")
        #expect(paths.first?.hasSuffix(".apply") == true, "its own applier copy, moved over `apply` only by the start")
        let staged = Array(paths.dropFirst())
        #expect(staged.first?.hasSuffix(".toml") == true && staged.last?.hasSuffix(".pending") == true,
                "the request is complete only when the start command renames .pending to .json, after the chown")
        #expect(recorder.writes.map(\.mode) == [0o700, 0o600, 0o600])
        #expect(recorder.writes[1].data == Self.toml, "the file goes as written: names and plain values only")
        #expect(String(decoding: recorder.writes[2].data, as: UTF8.self) == #"{"source":"uploaded"}"# + "\n")
        let id = String(staged.first?.split(separator: "/").last?.split(separator: ".").first ?? "")
        #expect(recorder.commands.count == 2 && recorder.commands.last?.contains("r=\(id);") == true, "the start finalizes only this request")
    }

    @Test func aReapplyWithoutAFileLetsTheMachinePickItsSource() async {
        let recorder = Recorder()
        _ = await CloudMachineConfig(contents: nil).apply(on: recorder.machine)
        #expect(!recorder.writes.contains { $0.path.hasSuffix(".toml") })
        #expect(recorder.writes.last.map { String(decoding: $0.data, as: UTF8.self) } == #"{"source":"auto"}"# + "\n")
    }

    @Test func aRunningApplyIsNotStartedAgainAndAFailedStartSaysWhy() async {
        let recorder = Recorder()
        recorder.startAnswer = CloudExecResult(exitCode: 0, stdout: "running\n", stderr: "")
        #expect(await CloudMachineConfig(contents: nil).apply(on: recorder.machine).status == "running")
        recorder.startAnswer = CloudExecResult(exitCode: 1, stdout: "", stderr: "the machine has no python3 with tomllib (3.11 or later)")
        let failed = await CloudMachineConfig(contents: nil).apply(on: recorder.machine)
        #expect(failed == CloudMachineBootstrap.Outcome(status: "failed", reason: "the machine has no python3 with tomllib (3.11 or later)"))
    }

    @Test func anUnreadableConfigIsRefusedBeforeAnyCreate() async throws {
        var request = CloudMachineRequest()
        request.machineConfigPath = "/nonexistent/\(UUID().uuidString)"
        await #expect(throws: CloudMachineRequest.ScriptUnreadable.self) { _ = try await request.loadMachineConfig(work: BackgroundWork()) }
    }

    @Test func theAnswerSaysHowToReadTheStatus() {
        let answer = CloudHandlers.machineConfigAnswer(.init(status: "started"), machineID: "vm-1")
        guard case .object(let fields) = answer else { Issue.record("not an object"); return }
        #expect(fields["status"] == .string("started"))
        #expect(fields["check"] == .string("cmux cloud file-read --target machine:vm-1 --path \(CloudMachineConfig.statusPath)"))
    }
}
