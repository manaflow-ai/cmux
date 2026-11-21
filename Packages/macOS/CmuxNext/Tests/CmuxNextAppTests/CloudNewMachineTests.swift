import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextCloud
import CmuxNextCloudUI
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

    /// `cmux cloud start-chat --environment` (Leo, 2026-11-06: "Like with a ... environment"): the create takes an
    /// environment by id or by name and never drops it on the plain path.
    @Test func anEnvironmentIsTakenByIDOrNameAndKeptOffThePlainPath() throws {
        typealias Option = CloudWorkspaceSetupWizard.EnvironmentOption
        let request = try CloudHandlers.newMachineRequest(Self.invocation(["environment": .string(" python-dev ")]))
        #expect(request.environment == "python-dev")
        #expect(!request.takesPlainPath, "the plain path would make the machine without its environment")
        #expect(try CloudHandlers.newMachineRequest(Self.invocation([:])).takesPlainPath)
        #expect(throws: Option.Unknown.self) { try CloudHandlers.newMachineRequest(Self.invocation(["environment": .bool(true)])) }
        #expect(throws: Option.Unknown.self) { try CloudHandlers.newMachineRequest(Self.invocation(["environment": .string(" ")])) }
        #expect(String(describing: Option.Unknown()).contains("--environment"), "the refusal reads as its message")
        let options = [Option(id: "env_1", name: "python-dev"), Option(id: "env_2", name: "Node")]
        #expect(try Option.id(for: "env_9", in: []) == "env_9")
        #expect(try Option.id(for: "python-dev", in: options) == "env_1")
        #expect(try Option.id(for: "node", in: options) == "env_2")
        #expect(throws: Option.Unknown.self) { try Option.id(for: "nope", in: options) }
    }

    /// The review of #37159: `--environment` with `--name` makes no second machine of that name. A list the
    /// server has not answered just now says nothing, a create of that name on its way (this app's, or a
    /// `cloud start-session --name` going on) takes the name, and an environment list that fails to load is
    /// that refusal, not "no such environment".
    @Test func aNamedEnvironmentCreateNeverMakesASecondMachine() async throws {
        typealias Option = CloudWorkspaceSetupWizard.EnvironmentOption
        #expect(CloudMachineRequest.namedCreate("py", listCurrent: false, machines: [], creating: []) == .unread)
        #expect(CloudMachineRequest.namedCreate("py", listCurrent: true, machines: ["py"], creating: []) == .taken)
        #expect(CloudMachineRequest.namedCreate("py", listCurrent: true, machines: [], creating: ["py"]) == .taken)
        #expect(CloudMachineRequest.namedCreate("py", listCurrent: true, machines: ["dev"], creating: ["other"]) == .free)

        let runs = CloudStartRuns<Int, Int>(), account: [String?] = ["user-1", "team-1"]
        let (gate, open) = AsyncStream<Void>.makeStream(), (entered, enter) = AsyncStream<Void>.makeStream()
        let making = Task { @MainActor in
            try await runs.creating("py", account: account) {
                enter.yield()
                for await _ in gate { break }
                return 1
            }
        }
        for await _ in entered { break }
        #expect(runs.isCreating("py", account: account), "a start-session creating py holds the name")
        #expect(!runs.isCreating("py", account: ["user-1", "team-2"]), "another team's create is not this one's")
        #expect(!runs.isCreating("dev", account: account))
        open.yield()
        open.finish()
        _ = try await making.value
        #expect(!runs.isCreating("py", account: account), "an ended create holds nothing")

        struct Down: Error {}
        await #expect(throws: Option.ListUnread.self) { _ = try await Option.id(for: "python-dev", loading: { throw Down() }) }
        #expect(try await Option.id(for: "env_9", loading: { throw Down() }) == "env_9", "an id needs no list")
        #expect(try await Option.id(for: "Python-Dev", loading: { [Option(id: "env_1", name: "python-dev")] }) == "env_1")
        #expect(String(describing: Option.ListUnread()).contains("environments"), "the refusal reads as its message")
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
                    // The start is the exec that launches the runner; the prepare answers nothing.
                    return command.contains("systemd-run") ? self.startAnswer : CloudExecResult(exitCode: 0, stdout: "", stderr: "")
                })
        }
    }

    @Test func theFallbackPathsAreRustsPaths() throws {
        let answered = try #require(CloudStartCore().call("cloud_bootstrap_facts", [String: String](), as: CloudMachineBootstrap.Facts.self))
        let fallback = CloudMachineBootstrap.Facts()
        #expect([answered.directory, answered.logPath, answered.statusPath, answered.configDirectory, answered.configStatusPath, answered.configLogPath]
            == [fallback.directory, fallback.logPath, fallback.statusPath, fallback.configDirectory, fallback.configStatusPath, fallback.configLogPath],
            "with no FFI answer the secrets receiver still lands in the config folder")
        #expect(CloudMachineSecrets.receiverPath.hasPrefix(fallback.configDirectory + "/"))
        #expect(CloudMachineRepo(owner: "o", name: "r", ref: "main").spec == "o/r@main")
        #expect(CloudMachineRepo(owner: "g/s", name: "r", host: "gitlab.com").spec == "https://gitlab.com/g/s/r")
    }

    @Test func theBootstrapUploadsTheScriptItsEnvironmentAndTheRunnerThenStartsIt() async {
        let fake = FakeMachine()
        let script = CloudMachineBootstrap(kind: .lane, contents: Data("#!/bin/sh\necho hi\n".utf8))
        let outcome = await script.start(name: "lane-vm-1", on: fake.machine, startID: "0f-1")
        #expect(outcome == CloudMachineBootstrap.Outcome(status: "started"))
        let staged = CloudMachineBootstrap.directory + "/in-0f-1"
        #expect(fake.writes.map(\.0) == ["\(staged)/script", "\(staged)/env", "\(staged)/run", "\(staged)/repo.json", "\(staged)/repo"])
        #expect(fake.writes.map(\.2) == [0o700, 0o600, 0o700, 0o644, 0o700])
        #expect(fake.writes[3].1 == Data("null\n".utf8), "no repo: no earlier start's record is left")
        #expect(fake.writes[4].1 == CloudMachineBootstrap.noScript, "and no earlier start's step")
        #expect(String(decoding: fake.writes[1].1, as: UTF8.self).contains("export LANE_VM_NAME='lane-vm-1'"))
        #expect(fake.commands.count == 2 && fake.commands.allSatisfy { $0.contains("s=\(staged);") }, "the prepare, then the start, of this start's folder")
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
}
