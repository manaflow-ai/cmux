@testable import CmuxNextApp
@testable import CmuxNextCloud
import CmuxNextCloudUI
import Foundation
import Observation
import Testing

/// The bootstrap's end for GUI callers (`CloudMachineBootstrap.Completion`): the New Cloud Workspace
/// wizard opens the clone at `repoPath` or shows why it failed, and the wait outlives the creation row.
extension CloudMachineRepoTests {
    typealias Run = CloudMachineBootstrap.Run
    static let repo = CloudMachineRepo(owner: "o", name: "r")
    static let clone = "/home/cmux/work/r"

    static func answer(_ status: String?, lock: String = "free", now: Int = 1000) -> CloudExecResult {
        CloudExecResult(exitCode: 0, stdout: "cmux-wait \(lock) \(now)\n" + (status.map { $0 + "\n" } ?? ""), stderr: "")
    }

    static func status(_ state: String, _ code: String = "null", repo: String = "null", at: Int = 990, late: Bool = false, step: String? = nil) -> String {
        let extra = (late ? #","late":true"# : "") + (step.map { #","step":"\#($0)""# } ?? "")
        return #"{"state":"\#(state)","exit_code":\#(code),"script_sha256":"a","start_sha256":"b","repo":\#(repo),"at":\#(at)\#(extra)}"#
    }

    static func repoStatus(_ status: String) -> String {
        #"{"status":"\#(status)","url":"https://github.com/o/r.git","ref":"","dir":"/home/cmux/work/r","credential":"none","sha":"abc"}"#
    }

    /// Answers each wait command from `answers` in order (an `Error` is thrown), recording the commands.
    nonisolated final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Result<CloudExecResult, any Error>]
        private(set) var commands: [String] = []

        init(_ answers: [Result<CloudExecResult, any Error>]) { self.answers = answers }

        var machine: CloudMachineBootstrap.Machine {
            CloudMachineBootstrap.Machine(write: { _, _, _ in }, exec: { command in
                try self.lock.withLock {
                    self.commands.append(command)
                    return try self.answers.removeFirst().get()
                }
            })
        }
    }

    struct Timeout: Error {}

    func run(_ bootstrap: CloudMachineBootstrap, _ answers: [Result<CloudExecResult, any Error>], bound: Duration = .seconds(60)) async -> (CloudMachineBootstrap.Run, Int) {
        let script = Script(answers)
        let run = await bootstrap.waitForRun(on: script.machine, bound: bound)
        return (run, script.commands.count)
    }

    var withRepo: CloudMachineBootstrap { CloudMachineBootstrap(kind: .plain, contents: CloudMachineBootstrap.noScript, repo: Self.repo) }
    var scriptOnly: CloudMachineBootstrap { CloudMachineBootstrap(kind: .plain, contents: Data("#!/bin/sh\n".utf8)) }

    @Test func aFinishedRunGivesTheClonePathOrNoneWithoutARepo() async {
        #expect(await run(withRepo, [.success(Self.answer(Self.status("done", "0", repo: Self.repoStatus("cloned"))))]) == (Run.finished(repoPath: Self.clone), 1))
        #expect(await run(withRepo, [.success(Self.answer(Self.status("done", "0", repo: Self.repoStatus("kept"))))]).0 == .finished(repoPath: "/home/cmux/work/r"))
        #expect(await run(scriptOnly, [.success(Self.answer(Self.status("done", "0")))]).0 == .finished(repoPath: nil))
        #expect(CloudMachineBootstrap.completion(.finished(repoPath: "/home/cmux/work/r")) == .finished(repoPath: "/home/cmux/work/r"))
    }

    @Test func eachFailureSaysWhyInWords() async {
        let needs = await run(withRepo, [.success(Self.answer(Self.status("failed", "3", repo: Self.repoStatus("needs_github"))))]).0
        #expect(needs == .needsGitHub(repo: "o/r"))
        #expect(CloudMachineBootstrap.completion(needs) == .repositoryFailed(reason: CloudGitHubConnectorCard.failureMessage(.privateRepository)))
        #expect(CloudStrings.bootstrapNeedsGitHub("o/r").contains("o/r"))
        let clone = await run(withRepo, [.success(Self.answer(Self.status("failed", "1", repo: Self.repoStatus("failed"))))]).0
        #expect(clone == .repoFailed(repo: "o/r"))
        let script = await run(scriptOnly, [.success(Self.answer(Self.status("failed", "7")))]).0
        #expect(script == .scriptFailed(exitCode: 7))
        #expect(CloudMachineBootstrap.completion(script) == .failed(reason: CloudStrings.bootstrapScriptFailed(7, log: CloudMachineBootstrap.logPath)))
        #expect(CloudStrings.bootstrapScriptFailed(7, log: "L").contains("7"))
        #expect(await run(withRepo, [.success(Self.answer(Self.status("failed", "75", late: true)))]).0 == .runnerNeverCame, "the runner came a minute late")
        #expect(await run(scriptOnly, [.success(Self.answer(Self.status("failed", "75")))]).0 == .scriptFailed(exitCode: 75), "a script's own exit 75")
        // The runner says which step failed: a script that exits 3 after a needs_github repo step is the script's failure,
        // the repo step's retry after it is the repo's, and a late refusal wins over any repo status.
        let needsGitHub = Self.repoStatus("needs_github")
        #expect(await run(withRepo, [.success(Self.answer(Self.status("failed", "3", repo: needsGitHub, step: "script")))]).0 == .scriptFailed(exitCode: 3))
        #expect(await run(withRepo, [.success(Self.answer(Self.status("failed", "3", repo: needsGitHub, step: "repo")))]).0 == .needsGitHub(repo: "o/r"))
        #expect(await run(withRepo, [.success(Self.answer(Self.status("failed", "75", repo: Self.repoStatus("failed"), late: true)))]).0 == .runnerNeverCame)
        #expect(await run(withRepo, [.success(Self.answer(Self.status("starting", at: 1000), now: 1100))]).0 == .runnerNeverCame)
        #expect(await run(withRepo, [.success(Self.answer(nil))]).0 == .runnerNeverCame, "no status at all")
        #expect(await run(withRepo, [.success(Self.answer(Self.status("running")))]).0 == .stopped, "`running` read under a free lock")
        // `running` with no `alive` yet raced the runner making it: read again, and the next read sees the run.
        #expect(await run(withRepo, [.success(Self.answer(Self.status("running"), lock: "none")),
                                     .success(Self.answer(Self.status("done", "0", repo: Self.repoStatus("cloned"))))]) == (Run.finished(repoPath: Self.clone), 2))
    }

    @Test func aSkippedStartReadsTheEarlierRunAtOnce() async {
        // `skipped`: the same script and repo step already finished here, so the lock is free and the status final.
        #expect(await run(withRepo, [.success(Self.answer(Self.status("done", "0", repo: Self.repoStatus("updated"))))]) == (Run.finished(repoPath: Self.clone), 1))
    }

    @Test func aReadCutOffWhileTheRunnerRunsIsIssuedAgain() async {
        let answers: [Result<CloudExecResult, any Error>] = [
            .success(Self.answer(Self.status("running"), lock: "held")),
            .failure(Timeout()),
            .success(Self.answer(Self.status("starting", at: 995))),
            .success(Self.answer(Self.status("done", "0", repo: Self.repoStatus("cloned")))),
        ]
        #expect(await run(withRepo, answers) == (Run.finished(repoPath: Self.clone), 4))
        let unreachable = await run(withRepo, [.failure(Timeout()), .failure(Timeout()), .failure(Timeout())])
        #expect(unreachable.1 == 3)
        guard case .unreachable = unreachable.0 else { Issue.record("three failed reads in a row end the wait"); return }
        // Cancelled during a read after two failed ones: still running, not unreachable.
        let cancelling = Script([.failure(Timeout()), .failure(Timeout())])
        let bootstrap = withRepo
        // Its own task: the cancel must not reach this test's task.
        let cancelled = await Task {
            await bootstrap.waitForRun(on: CloudMachineBootstrap.Machine(write: { _, _, _ in }, exec: { command in
                if cancelling.commands.count == 2 { withUnsafeCurrentTask { $0?.cancel() }; throw Timeout() }
                return try await cancelling.machine.exec(command)
            }))
        }.value
        #expect(cancelled == .stillRunning)
        let bounded = await run(withRepo, [.success(Self.answer(Self.status("running"), lock: "held"))], bound: .zero)
        #expect(bounded == (Run.stillRunning, 1))
        #expect(CloudMachineBootstrap.completion(.stillRunning) == .failed(reason: CloudStrings.bootstrapStillRunning(log: CloudMachineBootstrap.logPath)))
    }

    @Test func theReadBlocksOnTheRunnersLockAndNeverLoopsOnTheMachine() throws {
        let command = CloudMachineBootstrap.waitCommand
        #expect(command.contains(#"exec 8<"$d/alive"; then if flock -s -w 15 8; then w=free; n=$(date +%s); s=$(cat "$d/status.json""#),
                "a shared wait on the lock the runner holds for its life, and the status read while holding it")
        let starting = try #require(command.range(of: "then sleep 1; fi")), locked = try #require(command.range(of: "flock -s"))
        #expect(starting.upperBound < locked.lowerBound, "a `starting` read waits before it takes the lock, never between the lock and the status")
        #expect(!command.contains("while") && !command.contains("until"))
        #expect(CloudMachineBootstrap.runner.contains("exec 8>\"$d/alive\"\nflock 8\n"))
    }

    // MARK: The creation's wait

    /// A machine whose start says `started` and whose wait reads are answered by the test, one at a time.
    nonisolated final class GatedMachine: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        private var pending: CheckedContinuation<CloudExecResult, Never>?
        private var asked: CheckedContinuation<Void, Never>?

        var readCount: Int { lock.withLock { reads } }

        var machine: CloudMachineBootstrap.Machine {
            CloudMachineBootstrap.Machine(write: { _, _, _ in }, exec: { command in
                guard command == CloudMachineBootstrap.waitCommand else { return CloudExecResult(exitCode: 0, stdout: "started\n", stderr: "") }
                return await withCheckedContinuation { continuation in
                    let waiter = self.lock.withLock {
                        self.reads += 1
                        self.pending = continuation
                        defer { self.asked = nil }
                        return self.asked
                    }
                    waiter?.resume()
                }
            })
        }

        /// Returns once a read is waiting for its answer.
        func untilRead() async {
            await withCheckedContinuation { continuation in
                let ready = lock.withLock {
                    if pending != nil { return true }
                    asked = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        }

        func answer(_ result: CloudExecResult) {
            let continuation = lock.withLock { defer { pending = nil }; return pending }
            continuation?.resume(returning: result)
        }
    }

    @MainActor func repoCreation(_ creations: CloudCreations) -> CloudMachineCreation {
        var request = CloudMachineRequest(repo: Self.repo)
        request.script = withRepo
        return creations.begin(window: nil, request: request)
    }

    @MainActor final class Flag { var on = false }

    @MainActor @Test func theFlowOpensWithoutWaitingAndTheWaitOutlivesTheRow() async {
        let creations = CloudCreations(), fake = GatedMachine(), opened = Flag()
        let creation = repoCreation(creations)
        // The flow's task, as `CloudCreationFlow.run` makes it: the hook, then the open, then it waits
        // for the workspace's mirror (here: until the row's removal cancels it).
        let flow = Task { @MainActor in
            await CloudCreationFlow.startBootstrap(creation, on: fake.machine)
            opened.on = true
            try? await Task.sleep(for: .seconds(3600))
        }
        creation.task = flow
        await fake.untilRead()
        #expect(opened.on, "the hook returned while the machine still runs the bootstrap: the workspace opens")
        #expect(creation.bootstrap?.status == "started")
        #expect(creation.bootstrapCompletion == nil)
        // The workspace was mirrored: the row leaves and the flow's task is cancelled.
        creations.remove(creation)
        await flow.value
        #expect(creations.all.isEmpty)
        fake.answer(Self.answer(Self.status("done", "0", repo: Self.repoStatus("cloned"))))
        await creation.completionTask?.value
        #expect(creation.bootstrapCompletion == .finished(repoPath: Self.clone))
    }

    @MainActor @Test func tearingTheCreationDownStopsTheWait() async {
        let creations = CloudCreations(), fake = GatedMachine()
        let creation = repoCreation(creations)
        await CloudCreationFlow.startBootstrap(creation, on: fake.machine)
        await fake.untilRead()
        creations.end(creation)
        // The read in flight comes back still waiting: no read follows it.
        fake.answer(Self.answer(Self.status("running"), lock: "held"))
        await creation.completionTask?.value
        #expect(fake.readCount == 1)
        #expect(creation.bootstrapCompletion == nil)
    }

    nonisolated final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var on: Bool { lock.withLock { value } }
        func fire() { lock.withLock { value = true } }
    }

    @MainActor @Test func aCallerWaitingOnTheCompletionWakesWhenTheCreationEnds() async {
        let creations = CloudCreations(), fake = GatedMachine(), fired = Fired()
        let creation = repoCreation(creations)
        await CloudCreationFlow.startBootstrap(creation, on: fake.machine)
        await fake.untilRead()
        // The wizard's wait: the completion, or the creation's end, whichever comes first.
        withObservationTracking { _ = creation.bootstrapCompletion != nil || creation.isTornDown } onChange: { fired.fire() }
        creations.end(creation)
        #expect(fired.on, "the end is observable: a caller waiting on the completion stops")
        #expect(creation.isTornDown && creation.bootstrapCompletion == nil)
        fake.answer(Self.answer(Self.status("done", "0", repo: Self.repoStatus("cloned"))))
        await creation.completionTask?.value
        #expect(creation.bootstrapCompletion == nil, "a torn-down creation publishes no completion")
    }

    @MainActor @Test func aFlowCancelledDuringTheStartAppliesNoMachineConfig() async {
        var request = CloudMachineRequest(repo: Self.repo)
        request.script = withRepo
        request.machineConfig = CloudMachineConfig(contents: nil)
        let creation = CloudCreations().begin(window: nil, request: request), others = Fired()
        let machine = CloudMachineBootstrap.Machine(write: { _, _, _ in }, exec: { command in
            // The start goes out, then the flow is cancelled (a Retry) before it comes back.
            if command.contains("echo started") { withUnsafeCurrentTask { $0?.cancel() } }
            // The started bootstrap's wait reads on: only an apply would be another command.
            else if !command.contains("mkdir -p"), command != CloudMachineBootstrap.waitCommand { others.fire() }
            return CloudExecResult(exitCode: 0, stdout: "started\n", stderr: "")
        })
        await Task { @MainActor in await CloudCreationFlow.startBootstrap(creation, on: machine) }.value
        #expect(creation.machineConfig == nil && !others.on, "the apply waits for the Retry")
        #expect(CloudCreationFlow.needsMachineConfig(creation))
        creation.tearDown()
    }

    @MainActor @Test func aStartThatReturnsAfterTheTearDownStartsNoWait() {
        // The flow was cancelled while `start` was out on the machine; its outcome comes back afterwards.
        let creation = CloudMachineCreation(windowID: nil)
        let attempt = creation.beginBootstrapAttempt()
        creation.tearDown()
        creation.awaitBootstrapCompletion(CloudMachineBootstrap.Outcome(status: "started"), attempt: attempt) {
            Issue.record("a torn-down creation reads nothing")
            return .finished(repoPath: nil)
        }
        #expect(creation.completionTask == nil)
        #expect(creation.bootstrapCompletion == nil)
    }

    @MainActor @Test func aRetryDropsTheEarlierStartsLateOutcome() {
        let creation = CloudMachineCreation(windowID: nil)
        creation.awaitBootstrapCompletion(CloudMachineBootstrap.Outcome(status: "failed", reason: "x"), attempt: creation.beginBootstrapAttempt()) {
            .finished(repoPath: nil)
        }
        #expect(creation.bootstrapCompletion != nil)
        let first = creation.beginBootstrapAttempt()
        #expect(creation.bootstrapCompletion == nil, "a new start clears the last completion before it goes out")
        let second = creation.beginBootstrapAttempt()
        // The first start comes back after the Retry began the second: dropped.
        creation.awaitBootstrapCompletion(CloudMachineBootstrap.Outcome(status: "started"), attempt: first) {
            Issue.record("a stale start reads nothing")
            return .finished(repoPath: "/stale")
        }
        #expect(creation.completionTask == nil && creation.bootstrap?.status == "failed")
        creation.awaitBootstrapCompletion(CloudMachineBootstrap.Outcome(status: "failed", reason: "y"), attempt: second) { .finished(repoPath: nil) }
        #expect(creation.bootstrapCompletion == .failed(reason: CloudStrings.bootstrapStartFailed("y")))
    }

    @MainActor @Test func aStartThatFailedEndsAtOnceWithItsReason() {
        let creation = CloudMachineCreation(windowID: nil)
        creation.awaitBootstrapCompletion(CloudMachineBootstrap.Outcome(status: "failed", reason: "no sudo"), attempt: creation.beginBootstrapAttempt()) {
            Issue.record("a failed start reads nothing")
            return .finished(repoPath: nil)
        }
        #expect(creation.bootstrapCompletion == .failed(reason: CloudStrings.bootstrapStartFailed("no sudo")))
        #expect(creation.completionTask == nil)
    }
}
