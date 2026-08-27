import Foundation

extension GitMetadataService {
    /// The branch name git parks in a reftable repository's `HEAD` file.
    ///
    /// `extensions.refStorage = reftable` moves every ref, the `HEAD` symref
    /// included, into a binary stack under `reftable/`. The `HEAD` file stays
    /// behind only so that code which identifies a git directory by its
    /// presence keeps working, and it permanently reads
    /// `ref: refs/heads/.invalid`. `.invalid` is a name git itself refuses, so
    /// it can never collide with a real branch.
    static let reftablePlaceholderBranchName = ".invalid"

    /// The `reftable` directory inside a git directory.
    static let reftableDirectoryName = "reftable"

    /// The stack index git rewrites on every ref update.
    private static let reftableTablesListRelativePath = reftableDirectoryName + "/tables.list"

    /// Identity of the repository's reftable stack, or `nil` when the
    /// repository does not use reftable ref storage.
    ///
    /// `tables.list` names every table in the stack, and git replaces it on
    /// every ref update, so its contents serve as a cheap change signature for
    /// everything the stack holds. Both the per-worktree stack (which holds
    /// `HEAD`) and the common stack (which holds `refs/heads/*`) are included,
    /// because a branch switch rewrites the first and a commit rewrites the
    /// second.
    nonisolated static func reftableStackSignature(repository: ResolvedGitRepository) -> String? {
        let roots = repository.gitDirectory == repository.commonDirectory
            ? [repository.gitDirectory]
            : [repository.gitDirectory, repository.commonDirectory]
        // One component per root, present or not, so a stack that appears or
        // disappears cannot produce the same signature as its neighbour holding
        // the same contents.
        var components: [String] = []
        var foundStack = false
        for root in roots {
            let tablesListPath = joinedPath(
                root: root,
                relativePath: reftableTablesListRelativePath
            )
            guard let contents = try? String(
                contentsOf: URL(fileURLWithPath: tablesListPath),
                encoding: .utf8
            ) else {
                components.append("")
                continue
            }
            foundStack = true
            components.append(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return foundStack ? components.joined(separator: "\n") : nil
    }

    /// Whether the repository keeps its refs in a reftable stack rather than in
    /// ref files.
    nonisolated static func usesReftableRefStorage(repository: ResolvedGitRepository) -> Bool {
        reftableStackSignature(repository: repository) != nil
    }

    /// The branch a full symbolic ref name refers to, or `nil` when it names
    /// something other than a branch.
    nonisolated static func branchName(fromSymbolicFullName symbolicFullName: String) -> String? {
        let branchPrefix = "refs/heads/"
        guard symbolicFullName.hasPrefix(branchPrefix) else { return nil }
        return normalizedBranchName(String(symbolicFullName.dropFirst(branchPrefix.count)))
    }

    /// `HEAD` resolved through `git` for a reftable repository, or `nil` when
    /// the repository does not use reftable storage or `git` could not answer.
    nonisolated func reftableHead(repository: ResolvedGitRepository) -> GitReftableHead? {
        guard let stackSignature = Self.reftableStackSignature(repository: repository) else {
            return nil
        }
        return reftableHeadReader.head(
            workTreeRoot: repository.workTreeRoot,
            stackSignature: stackSignature
        )
    }

    /// The current branch name, falling back to reftable storage when the
    /// `HEAD` file cannot name one.
    nonisolated func resolvedBranchName(repository: ResolvedGitRepository) -> String? {
        if let branch = Self.gitBranchName(repository: repository) {
            return branch
        }
        guard let symbolicFullName = reftableHead(repository: repository)?.symbolicFullName else {
            return nil
        }
        return Self.branchName(fromSymbolicFullName: symbolicFullName)
    }

    /// The checked-out branch state, falling back to reftable storage when the
    /// `HEAD` file cannot be classified.
    nonisolated func resolvedCheckedOutBranch(
        repository: ResolvedGitRepository
    ) -> GitCheckedOutBranch {
        let parsed = Self.gitCheckedOutBranch(repository: repository)
        guard parsed == .unreadable, let head = reftableHead(repository: repository) else {
            return parsed
        }
        guard let symbolicFullName = head.symbolicFullName else {
            // No symbolic name: a detached checkout, as long as it resolves to
            // a commit. Neither name nor commit means nothing was resolved.
            return head.objectID == nil ? .unreadable : .detached
        }
        guard let branch = Self.branchName(fromSymbolicFullName: symbolicFullName) else {
            // A symbolic ref outside refs/heads, which is not a branch.
            return .detached
        }
        return .branch(branch)
    }

    /// A `HEAD` signature, falling back to reftable storage when the `HEAD`
    /// file carries no usable one. Mirrors the file-backed format: the symbolic
    /// ref text and the commit it resolves to, or the detached commit alone.
    nonisolated func resolvedHeadSignature(repository: ResolvedGitRepository) -> String? {
        if let signature = Self.gitHeadSignature(repository: repository) {
            return signature
        }
        guard let head = reftableHead(repository: repository) else { return nil }
        guard let symbolicFullName = head.symbolicFullName else {
            return head.objectID
        }
        return "ref: \(symbolicFullName)\n\(head.objectID ?? "")"
    }

    /// The commit `HEAD` resolves to, falling back to reftable storage when the
    /// ref files cannot resolve it.
    nonisolated func resolvedCurrentCommit(repository: ResolvedGitRepository) -> String? {
        if let commit = Self.gitCurrentCommit(repository: repository) {
            return commit
        }
        guard let objectID = reftableHead(repository: repository)?.objectID else { return nil }
        return Self.normalizedCommitID(objectID)
    }

    /// The branch name and `HEAD` signature for a metadata snapshot.
    ///
    /// A reftable repository resolves them through a `git` process, so that
    /// case runs on ``blockingStatusQueue`` like every other process this
    /// service starts, instead of occupying a cooperative-executor thread for
    /// the runner's wall-time bound. A repository on the files backend answers
    /// inline from the same reads as before, with no hop.
    nonisolated func headState(
        repository: ResolvedGitRepository
    ) async -> (branch: String?, headSignature: String?) {
        let branch = Self.gitBranchName(repository: repository)
        let headSignature = Self.gitHeadSignature(repository: repository)
        guard branch == nil || headSignature == nil,
              Self.usesReftableRefStorage(repository: repository) else {
            return (branch: branch, headSignature: headSignature)
        }
        return await onBlockingStatusQueue {
            (
                branch: resolvedBranchName(repository: repository),
                headSignature: resolvedHeadSignature(repository: repository)
            )
        }
    }

    /// The checked-out branch state, resolving reftable storage off the
    /// cooperative executor for the same reason as ``headState(repository:)``.
    nonisolated func checkedOutBranch(
        repository: ResolvedGitRepository
    ) async -> GitCheckedOutBranch {
        let parsed = Self.gitCheckedOutBranch(repository: repository)
        guard parsed == .unreadable, Self.usesReftableRefStorage(repository: repository) else {
            return parsed
        }
        return await onBlockingStatusQueue {
            resolvedCheckedOutBranch(repository: repository)
        }
    }

    /// Runs `work` on the queue this service reserves for blocking I/O.
    private nonisolated func onBlockingStatusQueue<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            Self.blockingStatusQueue.async {
                continuation.resume(returning: work())
            }
        }
    }
}
