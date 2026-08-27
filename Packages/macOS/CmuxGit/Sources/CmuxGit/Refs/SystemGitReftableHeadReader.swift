import Foundation

/// Resolves `HEAD` by asking `git`, the only reader of the reftable stack.
///
/// Two plumbing commands rather than one: `git rev-parse` applies
/// `--symbolic-full-name` to every revision that follows it, so a single run
/// cannot return both a ref name and an object id. Both are cheap — neither
/// reads the index or the working tree — and ``MemoizedGitReftableHeadReader``
/// keeps them off repeated refreshes.
struct SystemGitReftableHeadReader: GitReftableHeadReading {
    /// A ref name and an object id are both far below this. The bound only
    /// keeps a broken repository from streaming output into memory.
    private static let maximumOutputByteCount = 4096

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

    func head(workTreeRoot: String, stackSignature: String) -> GitReftableHead? {
        let directory = URL(fileURLWithPath: workTreeRoot, isDirectory: true)

        // `symbolic-ref --quiet` exits 1 for a detached HEAD and 128 for a
        // repository it cannot read at all. That is exactly the distinction
        // GitCheckedOutBranch draws between `detached` and `unreadable`, so
        // any other exit code has to stay unresolved.
        guard let symbolicRef = run(["symbolic-ref", "--quiet", "HEAD"], in: directory) else {
            return nil
        }
        let symbolicFullName: String?
        switch symbolicRef.exitCode {
        case 0:
            // Success with nothing to show would contradict itself; treat it as
            // unresolved rather than as a detached HEAD.
            guard !symbolicRef.text.isEmpty else { return nil }
            symbolicFullName = symbolicRef.text
        case 1:
            symbolicFullName = nil
        default:
            return nil
        }

        // Exits 1 on an unborn branch, where the ref name exists but no commit
        // does yet.
        let revParse = run(["rev-parse", "--verify", "--quiet", "HEAD"], in: directory)
        let objectID: String? = if let revParse, revParse.exitCode == 0, !revParse.text.isEmpty {
            revParse.text
        } else {
            nil
        }

        guard symbolicFullName != nil || objectID != nil else { return nil }
        return GitReftableHead(symbolicFullName: symbolicFullName, objectID: objectID)
    }

    private func run(
        _ arguments: [String],
        in directory: URL
    ) -> (text: String, exitCode: Int32)? {
        guard let result = try? runner.run(
            arguments: arguments,
            in: directory,
            maximumOutputByteCount: Self.maximumOutputByteCount
        ), !result.standardOutputWasTruncated else {
            return nil
        }
        let text = String(decoding: result.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text: text, exitCode: result.exitCode)
    }
}
