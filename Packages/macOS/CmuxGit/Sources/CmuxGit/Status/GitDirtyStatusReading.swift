import Foundation

/// Bounded fallback for repositories whose index is unsafe to scan entry by entry.
protocol GitDirtyStatusReading: Sendable {
    func isDirty(workTreeRoot: String) -> Bool?
}

struct SystemGitDirtyStatusReader: GitDirtyStatusReading {
    private let runner: any WorkspaceChangesGitRunning

    init(
        boundedCommandWallTimeLimit: TimeInterval = GitMetadataSafetyConfiguration().gitStatusWallTime
    ) {
        runner = SystemWorkspaceChangesGitRunner(
            boundedCommandWallTimeLimit: boundedCommandWallTimeLimit
        )
    }

    init(runner: any WorkspaceChangesGitRunning) {
        self.runner = runner
    }

    func isDirty(workTreeRoot: String) -> Bool? {
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
                maximumOutputByteCount: 1
            )
            // A dirty repository may intentionally terminate once the one-byte
            // output bound is crossed. Any byte is therefore authoritative even
            // when the bounded runner reports truncation or a signal exit.
            if !result.output.isEmpty {
                return true
            }
            guard result.exitCode == 0, !result.standardOutputWasTruncated else {
                return nil
            }
            return false
        } catch {
            return nil
        }
    }
}
