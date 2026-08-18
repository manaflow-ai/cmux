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
    private static let reftableTablesListRelativePath = "reftable/tables.list"

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
        var components: [String] = []
        for root in roots {
            let tablesListPath = joinedPath(
                root: root,
                relativePath: reftableTablesListRelativePath
            )
            guard let contents = try? String(
                contentsOf: URL(fileURLWithPath: tablesListPath),
                encoding: .utf8
            ) else {
                continue
            }
            components.append(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return components.isEmpty ? nil : components.joined(separator: "\n")
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
}
