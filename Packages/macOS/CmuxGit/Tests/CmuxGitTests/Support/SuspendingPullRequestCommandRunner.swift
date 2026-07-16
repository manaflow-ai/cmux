import CmuxFoundation
import Foundation

actor SuspendingPullRequestCommandRunner: CommandRunning {
    private let pullRequestViewOutput: String
    private let checksOutput: String
    private let commentsOutput: String
    private let mergeSettingsOutput: String
    private(set) var branchViewInvocationCount = 0
    private var branchViewCallCountWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var firstBranchViewContinuation: CheckedContinuation<Void, Never>?

    init(
        pullRequestViewOutput: String,
        checksOutput: String,
        commentsOutput: String,
        mergeSettingsOutput: String
    ) {
        self.pullRequestViewOutput = pullRequestViewOutput
        self.checksOutput = checksOutput
        self.commentsOutput = commentsOutput
        self.mergeSettingsOutput = mergeSettingsOutput
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        _ = (directory, executable, timeout)
        if arguments.starts(with: ["pr", "view"]),
           arguments.contains("number,title,state,url,statusCheckRollup,updatedAt,isDraft,mergeable,reviewDecision,mergeStateStatus,autoMergeRequest,baseRefName,headRefName,baseRefOid,headRefOid") {
            branchViewInvocationCount += 1
            let waiters = branchViewCallCountWaiters
                .removeValue(forKey: branchViewInvocationCount) ?? []
            waiters.forEach { $0.resume() }
            if branchViewInvocationCount == 1 {
                await withCheckedContinuation { firstBranchViewContinuation = $0 }
            }
            return success(pullRequestViewOutput)
        }
        if arguments.starts(with: ["pr", "checks"]) { return success(checksOutput) }
        if arguments.starts(with: ["pr", "view"]), arguments.contains("comments") {
            return success(commentsOutput)
        }
        if arguments.starts(with: ["repo", "view"]) { return success(mergeSettingsOutput) }
        return CommandResult(
            stdout: "",
            stderr: "unexpected arguments: \(arguments)",
            exitStatus: 1,
            timedOut: false,
            executionError: nil
        )
    }

    func waitForBranchViewInvocationCount(_ count: Int) async {
        guard branchViewInvocationCount < count else { return }
        await withCheckedContinuation { continuation in
            branchViewCallCountWaiters[count, default: []].append(continuation)
        }
    }

    func resumeFirstBranchView() {
        firstBranchViewContinuation?.resume()
        firstBranchViewContinuation = nil
    }

    private func success(_ output: String) -> CommandResult {
        CommandResult(
            stdout: output,
            stderr: nil,
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }
}
