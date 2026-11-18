import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemonService
import CmuxNextWakeups
import Foundation
import Testing

/// `cmux cloud new-machine --repo OWNER/NAME[@REF]` (CloudMachineRepo): the app's side of the spec and
/// the repo step. The forms, the checks and the step's text are Rust's, tested in
/// cmux-cloud-start-core's `machine_repo`.
@Suite
struct CloudMachineRepoTests {
    @Test func theAppSaysWhyWithoutEchoingTheSpec() {
        let invocation = ActionInvocation(arguments: ["repo": .string("https://ghp_secret@github.com/o/r")], origin: .cli)
        #expect(throws: ActionFailure.self) { try CloudHandlers.newMachineRequest(invocation) }
        do { _ = try CloudHandlers.newMachineRequest(invocation) } catch {
            #expect(!String(describing: error).contains("ghp_secret"))
        }
        #expect(throws: ActionFailure.self, "a bare --repo is refused, never a plain machine") {
            try CloudHandlers.newMachineRequest(ActionInvocation(arguments: ["repo": .bool(true)], origin: .cli))
        }
        let request = try? CloudHandlers.newMachineRequest(ActionInvocation(arguments: ["repo": .string("o/r@main")], origin: .cli))
        #expect(request?.isDefault == false)
        #expect(request?.repo == CloudMachineRepo(owner: "o", name: "r", ref: "main"))
    }

    /// A machine whose writes may come at once (``CloudMachineBootstrap``'s writes between two execs do): each is kept
    /// under a lock, with how many were in flight together and how many had finished when each exec ran.
    nonisolated final class FakeMachine: @unchecked Sendable {
        private let lock = NSLock()
        private var written: [String: Data] = [:]
        private var inFlight = 0
        private(set) var mostAtOnce = 0
        private(set) var writtenAtExec: [Int] = []
        /// Each write waits this long, so writes that overlap are seen overlapping.
        var writeDelay: Duration = .zero

        var writes: Set<String> { lock.withLock { Set(written.keys) } }
        func data(_ path: String) -> Data? { lock.withLock { written[path] } }

        var machine: CloudMachineBootstrap.Machine {
            CloudMachineBootstrap.Machine(write: { path, data, _ in
                self.lock.withLock { self.inFlight += 1; self.mostAtOnce = max(self.mostAtOnce, self.inFlight) }
                if self.writeDelay > .zero { try await Task.sleep(for: self.writeDelay) }
                self.lock.withLock { self.inFlight -= 1; self.written[path] = data }
            }, exec: { _ in
                self.lock.withLock { self.writtenAtExec.append(self.written.count) }
                return CloudExecResult(exitCode: 0, stdout: "started\n", stderr: "")
            })
        }
    }

    @Test func aRepoAloneStillRunsTheRunnerAndItsStepGoesBesideIt() async throws {
        let request = CloudMachineRequest(repo: CloudMachineRepo(owner: "o", name: "r"))
        let bootstrap = try #require(try await request.loadScript(work: BackgroundWork()))
        #expect(bootstrap.contents == CloudMachineBootstrap.noScript)
        let fake = FakeMachine()
        #expect(await bootstrap.start(name: nil, on: fake.machine, startID: "ab").status == "started")
        let staged = CloudMachineBootstrap.directory + "/in-ab"
        #expect(fake.writes == ["\(staged)/script", "\(staged)/env", "\(staged)/run", "\(staged)/repo.json", "\(staged)/repo"])
        let step = fake.data("\(staged)/repo")
        #expect(step == Data(CloudMachineRepo(owner: "o", name: "r").step.utf8))
        #expect(try await CloudMachineRequest().loadScript(work: BackgroundWork()) == nil)
    }

    /// A repository's start uploads five files between its prepare and its start: one round trip's wait for all of
    /// them, not five in a row, and the start runs only once every one is there.
    @Test func theStartsFilesGoAtOnceAndAllBeforeItRuns() async throws {
        let request = CloudMachineRequest(repo: CloudMachineRepo(owner: "o", name: "r"))
        let bootstrap = try #require(try await request.loadScript(work: BackgroundWork()))
        let fake = FakeMachine()
        fake.writeDelay = .milliseconds(50)
        #expect(await bootstrap.start(name: nil, on: fake.machine, startID: "ab").status == "started")
        #expect(fake.mostAtOnce == 5)
        // The prepare before any write; the start after all five.
        #expect(fake.writtenAtExec == [0, 5])
    }

    @MainActor @Test func aRetryStartsABootstrapThatHasNotStartedOrFailed() {
        var request = CloudMachineRequest(repo: CloudMachineRepo(owner: "o", name: "r"))
        request.script = CloudMachineBootstrap(kind: .plain, contents: CloudMachineBootstrap.noScript, repo: request.repo)
        let creation = CloudMachineCreation(windowID: nil, request: request)
        #expect(CloudCreationFlow.needsBootstrap(creation), "not started yet")
        creation.noteBootstrap(CloudMachineBootstrap.Outcome(status: "failed", reason: "upload failed"))
        #expect(CloudCreationFlow.needsBootstrap(creation), "a failed start is tried again")
        creation.noteBootstrap(CloudMachineBootstrap.Outcome(status: "running"))
        #expect(!CloudCreationFlow.needsBootstrap(creation), "a start the machine took is not sent twice")
        #expect(!CloudCreationFlow.needsBootstrap(CloudMachineCreation(windowID: nil)), "no bootstrap asked")
        var configured = CloudMachineRequest()
        configured.machineConfig = CloudMachineConfig(contents: nil)
        let applying = CloudMachineCreation(windowID: nil, request: configured)
        #expect(CloudCreationFlow.needsBootstrap(applying) && !CloudCreationFlow.needsScript(applying), "a machine config alone still gets its apply")
        applying.noteMachineConfig(CloudMachineBootstrap.Outcome(status: "started"))
        #expect(!CloudCreationFlow.needsBootstrap(applying), "an apply the machine took is not sent twice")
    }
}
