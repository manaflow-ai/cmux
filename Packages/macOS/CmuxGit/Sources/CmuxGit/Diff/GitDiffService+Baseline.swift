extension GitDiffService {
    /// `git diff HEAD` fails before the first commit. In that state Git's
    /// hash-format-aware empty tree is the correct baseline for index and
    /// working-tree changes, including files already staged in the index.
    /// A broken HEAD must fail closed instead of taking the same fallback.
    func diffBaselineResult(in repoRoot: String) -> GitDiffQueryResult<String> {
        let head = runGit(
            in: repoRoot,
            arguments: ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]
        )
        switch head.failure {
        case nil:
            guard let output = head.successOutput,
                  let objectID = removingGitLineTerminator(output),
                  !objectID.isEmpty else { return .failed }
            return .success(objectID)
        case .unsuccessfulExit:
            break
        case .timedOut:
            return .timedOut
        case .cancelled, .launchFailed:
            return .failed
        }
        let symbolicHead = runGit(
            in: repoRoot,
            arguments: ["symbolic-ref", "--quiet", "HEAD"]
        )
        guard symbolicHead.failure == nil,
              let symbolicOutput = symbolicHead.successOutput,
              let headRef = removingGitLineTerminator(symbolicOutput),
              headRef.hasPrefix("refs/heads/"),
              headRef != "refs/heads/" else { return .failed }
        // `show-ref` without a pattern validates every branch ref. Exit 1 is
        // the valid no-refs state; any other failure identifies corrupt ref
        // storage. Bound its otherwise irrelevant output and fail closed when
        // an unusually large ref set reaches that cap.
        let branchRefs = runGit(
            in: repoRoot,
            arguments: ["show-ref", "--hash", "--abbrev=1", "--heads"],
            acceptedTerminationStatuses: [0, 1],
            maxOutputBytes: 64 * 1024
        )
        guard branchRefs.failure == nil, !branchRefs.capped else { return .failed }
        let currentRef = runGit(
            in: repoRoot,
            arguments: ["show-ref", "--verify", "--quiet", headRef],
            acceptedTerminationStatuses: [0, 1]
        )
        guard currentRef.failure == nil else { return .failed }
        // Exit 1 means the symbolic branch does not exist yet. Exit 0 after
        // HEAD^{commit} failed means a ref exists but cannot resolve to a
        // commit, which is repository corruption rather than an unborn branch.
        guard currentRef.terminationStatus == 1 else { return .failed }
        let emptyTree = runGit(in: repoRoot, arguments: ["hash-object", "-t", "tree", "/dev/null"])
        if let failure: GitDiffQueryResult<String> = queryFailure(from: emptyTree) {
            return failure
        }
        guard let output = emptyTree.successOutput,
              let baseline = removingGitLineTerminator(output),
              !baseline.isEmpty else { return .failed }
        return .success(baseline)
    }

    /// Git terminates one scalar result with a line ending. Remove only that
    /// protocol terminator, preserving valid spaces and newlines in paths.
    func removingGitLineTerminator(_ output: String) -> String? {
        if output.hasSuffix("\r\n") {
            return String(output.dropLast(2))
        }
        if output.hasSuffix("\n") || output.hasSuffix("\r") {
            return String(output.dropLast())
        }
        return output
    }

    func queryFailure<Value: Sendable>(
        from result: GitProcessResult
    ) -> GitDiffQueryResult<Value>? {
        switch result.failure {
        case .timedOut:
            return .timedOut
        case .cancelled, .launchFailed, .unsuccessfulExit:
            return .failed
        case nil:
            return nil
        }
    }

    func runGit(
        in directory: String,
        arguments: [String],
        acceptedTerminationStatuses: Set<Int32> = [0],
        maxOutputBytes: Int? = nil
    ) -> GitProcessResult {
        processRunner.run(
            in: directory,
            arguments: arguments,
            acceptedTerminationStatuses: acceptedTerminationStatuses,
            maxOutputBytes: maxOutputBytes,
            deadlineSeconds: remainingOperationDeadlineSeconds
        )
    }
}
