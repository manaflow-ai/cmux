import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextWakeups
import Foundation
import Testing

/// `.cmux/machine.toml` (CloudMachineConfig): the applier the machine runs and the bootstrap start's half
/// of their handshake (`start.lock`); an apply uploads the file, its request and the applier over the
/// file API, then starts it with one short exec. A reapply with no file uploads none and lets the
/// machine pick its source.
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
                    return command == CloudMachineConfig.prepareCommand ? CloudExecResult(exitCode: 0, stdout: "", stderr: "") : self.startAnswer
                })
        }
    }

    static let toml = Data("version = 1\n[env]\nNODE_ENV = \"development\"\n[secrets]\nnames = [\"DATABASE_URL\"]\n[setup]\nrun = [\"bun install\"]\n".utf8)

    @Test func theApplierKeepsItsFilesPrivateAndNeverRoutesTheModelPlane() {
        for name in ["OPENAI_BASE_URL", "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "OPTIND", "PS1", "ZDOTDIR"] {
            #expect(CloudMachineConfig.applier.contains("\"\(name)\""), "a file from a repo never routes the model plane: \(name)")
        }
        #expect(CloudMachineConfig.applier.contains("def write(path, text, mode=0o600)"))
        #expect(CloudMachineConfig.applier.hasPrefix("#!/usr/bin/env python3\n"))
        #expect(!CloudMachineConfig.applier.contains("log_tail"), "no setup output in status.json, which the app reads over the file API")
        #expect(CloudMachineConfig.applier.contains(#"='((?:[^']|'\\'')*)'"#) && !CloudMachineConfig.applier.contains("len(value) >="),
                "every delivered value is masked in setup's log, however short, multi-line ones too")
    }

    @Test func aBootstrapStartWaitsForARunningApplyAndNeverRerunsADoneScript() throws {
        let start = CloudMachineBootstrap.startCommand(CloudMachineBootstrap.stagingDirectory("ab"))
        let lock = try #require(start.range(of: "flock -w 15 7"))
        let runner = try #require(start.range(of: "flock -n 6"))
        let done = try #require(start.range(of: #""\"state\":\"done\".*"#))
        let starting = try #require(start.range(of: #"printf '{"state":"starting""#))
        let release = try #require(start.range(of: "exec 6<&-"))
        let launch = try #require(start.range(of: "systemd-run"))
        #expect(lock.lowerBound < runner.lowerBound && runner.lowerBound < done.lowerBound && done.lowerBound < starting.lowerBound
                    && starting.lowerBound < release.lowerBound && release.lowerBound < launch.lowerBound,
                "under start.lock and the runner's lock: a running runner, then a done script, then `starting`; the lock goes before the launch")
        #expect(CloudMachineBootstrap.runner.contains(#"if grep -q "\"state\":\"done\".*"#),
                "a runner an earlier start launched late finds the script done and does not run it again")
        #expect(start.contains("7<&-"), "the setsid runner never inherits start.lock")
        #expect(CloudMachineBootstrap.runner.contains(#"exec 8>"$d/alive""#), "the runner holds `alive` for its whole life")
        #expect(CloudMachineBootstrap.runner.contains(#"[ -f "$d/alive" ] && [ ! -L "$d/alive" ] || rm -f "$d/alive""#),
                "a link or FIFO at `alive` is replaced by a regular file before it is locked")
        #expect(start.contains(#"[ -f "$d/start.lock" ] && [ ! -L "$d/start.lock" ]"#), "a FIFO start.lock is refused, never opened")
    }

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
        let directory = CloudMachineConfig.directory
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
        #expect(recorder.commands == [CloudMachineConfig.prepareCommand, CloudMachineConfig.startCommand(request: id)],
                "the start finalizes only this request")
    }

    @Test func requestNamesSortByTime() {
        let early = CloudMachineConfig.requestID(Date(timeIntervalSince1970: 9)), late = CloudMachineConfig.requestID(Date(timeIntervalSince1970: 10))
        #expect(early < late)
        #expect(early.hasPrefix("0000000009000-"))
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

    @Test func theApplierStartsIsolated() {
        let start = CloudMachineConfig.startCommand(request: "0000000000001-abcdef01")
        #expect(start.contains(#""$py" -I "$d/apply""#), "-I: no user site or cwd module shadows the applier's imports")
        #expect(start.contains(#""$py" -I -c 'import tomllib'"#), "the probe too: PYTHONHOME or PYTHONPATH never decide it")
        #expect(start.contains("r=0000000000001-abcdef01") && !start.contains("*.pending"), "only this request's files are finalized")
        #expect(start.contains("command -v setsid >/dev/null 2>&1 || {"), "no way to start it is a failure, never a silent `started`")
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
