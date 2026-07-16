import CmuxFoundation
import Foundation

actor ConcurrencyTrackingPullRequestCommandRunner: CommandRunning {
    private let probe: PullRequestRefreshSchedulingProbe

    init(probe: PullRequestRefreshSchedulingProbe) {
        self.probe = probe
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        _ = (directory, executable, timeout)
        guard arguments.starts(with: ["pr", "view"]),
              arguments.contains(
                "number,title,state,url,statusCheckRollup,updatedAt,isDraft,mergeable,reviewDecision,mergeStateStatus,autoMergeRequest,baseRefName,headRefName,baseRefOid,headRefOid"
              ),
              arguments.count > 2 else {
            return failure()
        }

        await probe.branchViewStarted(branch: arguments[2])
        await probe.waitUntilBranchViewsAreReleased()
        await probe.branchViewEnded()
        return failure()
    }

    private func failure() -> CommandResult {
        CommandResult(
            stdout: nil,
            stderr: "fixture failure",
            exitStatus: 1,
            timedOut: false,
            executionError: nil
        )
    }
}
