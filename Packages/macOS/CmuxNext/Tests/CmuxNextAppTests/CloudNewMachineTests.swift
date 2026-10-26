import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextWakeups
import CmuxNextDaemonService
import Foundation
import Testing

/// `cmux cloud new-machine --persistent --size medium --name lane-vm-1 --bootstrap lane
/// --bootstrap-script FILE` makes a lane host in one call (leo-workspace machines/lane-vms.md):
/// the options parse into one request, the create sends its size and idle pause, and the
/// bootstrap goes over the file API and starts with one short exec.
@MainActor @Suite
struct CloudNewMachineTests {
    static func invocation(_ arguments: [String: ActionValue]) -> ActionInvocation {
        ActionInvocation(arguments: arguments, origin: .cli)
    }

    // MARK: The request

    @Test func noOptionsIsTheDefaultCreate() throws {
        let request = try CloudHandlers.newMachineRequest(Self.invocation([:]))
        #expect(request.isDefault)
        #expect(request.memoryMb == nil)
    }

    @Test func theLaneOptionsParseIntoOneRequest() throws {
        let request = try CloudHandlers.newMachineRequest(Self.invocation([
            "name": .string("lane-vm-1"), "size": .string("medium"), "persistent": .bool(true),
            "bootstrap": .string("lane"), "bootstrapScript": .string("/tmp/lane-vm-bootstrap"),
        ]))
        #expect(!request.isDefault)
        #expect(request.name == "lane-vm-1")
        #expect(request.size == "medium")
        #expect(request.memoryMb == 8192, "medium is 4 vCPU / 8 GiB, the lane VM size")
        #expect(request.persistent)
        #expect(request.bootstrapKind == .lane)
        #expect(request.bootstrapPath == "/tmp/lane-vm-bootstrap")
    }

    @Test func aCreateSizeSaysTheVCPUsTheServerLadderGives() throws {
        let request = try CloudHandlers.newMachineRequest(Self.invocation(["size": .string("xlarge")]))
        #expect(request.memoryMb == 24576)
        #expect(CloudHandlers.newMachineFields(request, nil)["cpu"] == .int(12), "24 GiB is the 12 vCPU row, not resize's 16")
    }

    @Test func anUnknownSizeIsRefusedWithTheChoices() {
        #expect(throws: ActionFailure.self) { try CloudHandlers.newMachineRequest(Self.invocation(["size": .string("huge")])) }
    }

    @Test func aLaneBootstrapNeedsItsScriptAndAName() {
        #expect(throws: ActionFailure.self) { try CloudHandlers.newMachineRequest(Self.invocation(["bootstrap": .string("lane"), "name": .string("lane-vm-1")])) }
        #expect(throws: ActionFailure.self) { try CloudHandlers.newMachineRequest(Self.invocation(["bootstrap": .string("lane"), "bootstrapScript": .string("/tmp/x")])) }
        #expect(throws: ActionFailure.self) { try CloudHandlers.newMachineRequest(Self.invocation(["bootstrap": .string("other"), "bootstrapScript": .string("/tmp/x")])) }
    }

    @Test func aScriptWithoutALaneIsAPlainBootstrap() throws {
        let request = try CloudHandlers.newMachineRequest(Self.invocation(["bootstrapScript": .string("/tmp/setup.sh")]))
        #expect(request.bootstrapKind == .plain)
        #expect(!request.isDefault)
    }

    @Test func aTextFlagWithNoValueIsRefusedNotIgnored() {
        for name in ["bootstrapScript", "bootstrap", "size", "name"] {
            #expect(throws: ActionFailure.self, "\(name)") { try CloudHandlers.newMachineRequest(Self.invocation([name: .bool(true)])) }
        }
    }

    @Test func aNameIsAPlainWordAndABareFlagIsNotOne() {
        for bad in ["true", "a b", "it's", "-x", "lane;vm", String(repeating: "a", count: 65)] {
            #expect(throws: ActionFailure.self, "\(bad)") { try CloudHandlers.newMachineRequest(Self.invocation(["name": .string(bad)])) }
        }
        #expect((try? CloudHandlers.newMachineRequest(Self.invocation(["name": .string("lane-vm-7")])))?.name == "lane-vm-7")
    }

    @Test func aFifoOrDeviceIsNotReadAsAScript() async throws {
        let request = try CloudHandlers.newMachineRequest(Self.invocation(["bootstrapScript": .string("/dev/zero")]))
        await #expect(throws: CloudMachineRequest.ScriptUnreadable.self) { _ = try await request.loadScript(work: BackgroundWork()) }
    }

    @Test func everyMachineCommandNamesTheWorkUser() {
        #expect(CloudMachineBootstrap.prepareCommand.contains("root chown cmux:cmux"))
        #expect(CloudMachineBootstrap.startCommand.contains(#"--uid="$u""#))
        #expect(CloudMachineBootstrap.startCommand.contains(#"as_u env HOME="$h" setsid"#), "the fallback runs as the work user too")
    }

    @Test func aQuotedTildeScriptIsTheHomeFolders() throws {
        let request = try CloudHandlers.newMachineRequest(Self.invocation(["bootstrapScript": .string("~/boot.sh")]))
        #expect(request.bootstrapPath == NSHomeDirectory() + "/boot.sh")
    }

    @Test func aRetryOfTheSameRequestSendsTheSameKey() {
        let request = CloudMachineRequest(name: "lane-vm-1", persistent: true)
        #expect(request.idempotencyKey == request.idempotencyKey)
        #expect(request.idempotencyKey != CloudMachineRequest(name: "lane-vm-1", persistent: true).idempotencyKey)
    }

    @Test func anUnreadableScriptIsRefusedBeforeAnyCreate() async throws {
        let request = try CloudHandlers.newMachineRequest(Self.invocation(["bootstrapScript": .string("/nonexistent/\(UUID().uuidString)")]))
        await #expect(throws: CloudMachineRequest.ScriptUnreadable.self) { _ = try await request.loadScript(work: BackgroundWork()) }
    }

    @Test func theAnswerSaysPersistentOnlyWhenTheServerStoredOff() throws {
        let request = CloudMachineRequest(name: "lane-vm-1", size: "medium", memoryMb: 8192, persistent: true)
        let stored = try JSONDecoder().decode(CloudMachine.self, from: Data(#"{"id":"vm-1","status":"running","idlePauseMinutes":0,"address":{"ipv4":"10.0.0.7"}}"#.utf8))
        let fields = CloudHandlers.newMachineFields(request, stored)
        #expect(fields["persistent"] == .bool(true))
        #expect(fields["idle_pause_minutes"] == .int(0))
        #expect(fields["cpu"] == .int(4))
        #expect(fields["memory_mb"] == .int(8192))
        #expect(fields["address"] == .string("10.0.0.7"))
        let notStored = try JSONDecoder().decode(CloudMachine.self, from: Data(#"{"id":"vm-2","status":"running","idlePauseMinutes":30}"#.utf8))
        #expect(CloudHandlers.newMachineFields(request, notStored)["persistent"] == .bool(false))
        let pending = CloudHandlers.newMachineFields(request, nil)
        #expect(pending["persistent"] == nil, "no machine yet: nothing stored to report")
        #expect(pending["persistent_requested"] == .bool(true))
        #expect(pending["memory_mb"] == .int(8192))
    }

    // MARK: The bootstrap

    nonisolated final class FakeMachine: @unchecked Sendable {
        var writes: [(String, Data, Int)] = []
        var commands: [String] = []
        var startAnswer = CloudExecResult(exitCode: 0, stdout: "started\n", stderr: "")

        var machine: CloudMachineBootstrap.Machine {
            CloudMachineBootstrap.Machine(
                write: { path, data, mode in self.writes.append((path, data, mode)) },
                exec: { command in
                    self.commands.append(command)
                    return command == CloudMachineBootstrap.prepareCommand ? CloudExecResult(exitCode: 0, stdout: "", stderr: "") : self.startAnswer
                })
        }
    }

    @Test func theBootstrapUploadsTheScriptItsEnvironmentAndTheRunnerThenStartsIt() async {
        let fake = FakeMachine()
        let script = CloudMachineBootstrap(kind: .lane, contents: Data("#!/bin/sh\necho hi\n".utf8))
        let outcome = await script.start(name: "lane-vm-1", on: fake.machine)
        #expect(outcome == CloudMachineBootstrap.Outcome(status: "started"))
        #expect(fake.writes.map(\.0) == ["\(CloudMachineBootstrap.directory)/script", "\(CloudMachineBootstrap.directory)/env", "\(CloudMachineBootstrap.directory)/run"])
        #expect(fake.writes.map(\.2) == [0o700, 0o600, 0o700])
        #expect(String(decoding: fake.writes[1].1, as: UTF8.self).contains("export LANE_VM_NAME='lane-vm-1'"))
        #expect(fake.commands == [CloudMachineBootstrap.prepareCommand, CloudMachineBootstrap.startCommand])
    }

    @Test func aBootstrapAlreadyDoneOrRunningIsNotStartedAgain() async {
        let fake = FakeMachine()
        let script = CloudMachineBootstrap(kind: .plain, contents: Data("true\n".utf8))
        fake.startAnswer = CloudExecResult(exitCode: 0, stdout: "skipped\n", stderr: "")
        #expect(await script.start(name: nil, on: fake.machine).status == "skipped")
        fake.startAnswer = CloudExecResult(exitCode: 0, stdout: "running\n", stderr: "")
        #expect(await script.start(name: nil, on: fake.machine).status == "running")
    }

    @Test func aStartThatFailsSaysWhy() async {
        let fake = FakeMachine()
        fake.startAnswer = CloudExecResult(exitCode: 1, stdout: "", stderr: "sha256sum: not found")
        let outcome = await CloudMachineBootstrap(kind: .plain, contents: Data("true\n".utf8)).start(name: nil, on: fake.machine)
        #expect(outcome == CloudMachineBootstrap.Outcome(status: "failed", reason: "sha256sum: not found"))
    }

    @Test func theEnvironmentQuotesTheNameAndOnlyALaneGetsTheLaneName() {
        #expect(CloudMachineBootstrap.environment(.plain, name: "it's") == "export CMUX_MACHINE_NAME='it'\\''s'\n")
        #expect(!CloudMachineBootstrap.environment(.plain, name: "box").contains("LANE_VM_NAME"))
        #expect(CloudMachineBootstrap.environment(.lane, name: nil).isEmpty)
    }

    @Test func aLaneAnswerNamesTheRegistryCommand() throws {
        let request = CloudMachineRequest(name: "lane-vm-3", size: "medium", memoryMb: 8192, persistent: true,
                                          bootstrapPath: "/tmp/lane-vm-bootstrap", bootstrapKind: .lane)
        let machine = try JSONDecoder().decode(CloudMachine.self, from: Data(#"{"id":"vm-3","status":"running","address":{"ipv4":"10.0.0.9"}}"#.utf8))
        let answer = CloudHandlers.newMachineEnrollment(request, machine)
        #expect(answer["registry_command"] == .string("tools/lane-vm-enroll lane-vm-3 vm-3 --address 10.0.0.9 --apply"))
        #expect(answer["enroll_command"] == .string("cmux cloud enroll-machine --target machine:vm-3 --name lane-vm-3"))
        #expect(CloudHandlers.newMachineEnrollment(CloudMachineRequest(), machine)["registry_command"] == nil)
    }
}
