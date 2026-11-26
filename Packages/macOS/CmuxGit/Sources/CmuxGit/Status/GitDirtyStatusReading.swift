import Foundation
import Dispatch

/// Bounded fallback for repositories whose index is unsafe to scan entry by entry.
protocol GitDirtyStatusReading: Sendable {
    func isDirty(workTreeRoot: String) -> Bool?
}

struct SystemGitDirtyStatusReader: GitDirtyStatusReading {
    private let runnerSelector: GitReferenceRunnerSelector

    init(
        boundedCommandWallTimeLimit: TimeInterval = GitMetadataSafetyConfiguration().gitStatusWallTime
    ) {
        runnerSelector = GitReferenceRunnerSelector(
            wallTimeLimit: boundedCommandWallTimeLimit,
            // `git status` must honor the user's global/system attributes and
            // filters (for example Git LFS). Only repository-selection
            // variables are stripped by the runner; reference plumbing uses
            // isolated mode to avoid unrelated global config.
            isolateRepositoryConfig: false,
            probesReferenceFormat: false
        )
    }

    init(runner: any WorkspaceChangesGitRunning) {
        self.runnerSelector = GitReferenceRunnerSelector(runner: runner)
    }

    func isDirty(workTreeRoot: String) -> Bool? {
        let candidates = runnerSelector.candidateRunners
        let deadline = DispatchTime.now() + runnerSelector.candidateWallTimeLimit
        for runner in candidates {
            let now = DispatchTime.now()
            guard deadline > now else { break }
            let remaining = Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds)
                / 1_000_000_000
            do {
                let result = try runner.run(
                    arguments: [
                        "status",
                        "--porcelain=v1",
                        "-z",
                        "--untracked-files=no",
                        "--ignore-submodules=dirty",
                        "--no-renames",
                    ],
                    in: URL(fileURLWithPath: workTreeRoot, isDirectory: true),
                    maximumOutputByteCount: 1,
                    wallTimeLimit: remaining
                )
                // A dirty repository may intentionally terminate once the one-byte
                // output bound is crossed. Any byte is therefore authoritative even
                // when the bounded runner reports truncation or a signal exit.
                if !result.output.isEmpty {
                    return true
                }
                if result.exitCode == 0, !result.standardOutputWasTruncated {
                    return false
                }
            } catch {
                continue
            }
        }
        return nil
    }
}
