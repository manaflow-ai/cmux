import Foundation

/// Resolves Git scope and produces capped changed-file snapshots.
struct WorkspaceChangesSnapshotLoader: Sendable {
    static let maximumFileCount = 500
    static let maximumSnapshotCommandOutputByteCount = 32 * 1024 * 1024
    private static let emptyTreeOID = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    private let runner: any WorkspaceChangesGitRunning
    private let parser = WorkspaceChangesParser()
    private let untrackedInspector: WorkspaceUntrackedFileInspector

    init(
        runner: any WorkspaceChangesGitRunning,
        untrackedInspector: WorkspaceUntrackedFileInspector = WorkspaceUntrackedFileInspector()
    ) {
        self.runner = runner
        self.untrackedInspector = untrackedInspector
    }

    func resolveScope(
        forDirectory directory: String
    ) throws(WorkspaceChangesServiceError) -> WorkspaceChangesScope? {
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        let rootResult: WorkspaceChangesGitResult
        do {
            rootResult = try runner.run(
                arguments: ["rev-parse", "--show-toplevel"],
                in: directoryURL
            )
        } catch {
            throw .gitFailure
        }
        guard rootResult.exitCode == 0 else { return nil }
        let repoRoot = String(decoding: rootResult.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repoRoot.isEmpty else { throw .gitFailure }

        let branch = try output(
            arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"],
            repoRoot: repoRoot,
            acceptedExitCodes: [0, 1]
        )
        let defaultRef = try resolveDefaultBranch(repoRoot: repoRoot)
        let baseRef: String?
        let diffBase: String
        if let branch,
           let defaultRef,
           branch != defaultRef,
           defaultRef != "origin/\(branch)",
           let mergeBase = try output(
               arguments: ["merge-base", "HEAD", defaultRef],
               repoRoot: repoRoot,
               acceptedExitCodes: [0]
           ) {
            baseRef = defaultRef
            diffBase = mergeBase
        } else {
            baseRef = nil
            // This is the designed default-branch behavior: there is no comparison
            // branch on the default branch, so HEAD intentionally shows uncommitted work.
            diffBase = "HEAD"
        }
        let verifiedBaseCommitOID = try output(
            arguments: ["rev-parse", "--verify", "\(diffBase)^{commit}"],
            repoRoot: repoRoot,
            acceptedExitCodes: [0]
        )
        let resolvedDiffBase: String
        let diffBaseCommitOID: String
        if let verifiedBaseCommitOID {
            resolvedDiffBase = verifiedBaseCommitOID
            diffBaseCommitOID = verifiedBaseCommitOID
        } else if diffBase == "HEAD" {
            resolvedDiffBase = Self.emptyTreeOID
            diffBaseCommitOID = Self.emptyTreeOID
        } else {
            throw .gitFailure
        }
        return WorkspaceChangesScope(
            repoRoot: repoRoot,
            branch: branch,
            baseRef: baseRef,
            diffBase: resolvedDiffBase,
            diffBaseCommitOID: diffBaseCommitOID
        )
    }

    func loadSnapshot(
        scope: WorkspaceChangesScope
    ) throws(WorkspaceChangesServiceError) -> WorkspaceChangesSnapshot {
        let statusResult = try run(
            ["diff", "-M", "--name-status", "-z", scope.diffBase, "--"],
            repoRoot: scope.repoRoot,
            maximumOutputByteCount: Self.maximumSnapshotCommandOutputByteCount
        )
        guard succeededOrTruncated(statusResult) else { throw .gitFailure }
        let numstatResult = try run(
            ["diff", "-M", "--numstat", "-z", scope.diffBase, "--"],
            repoRoot: scope.repoRoot,
            maximumOutputByteCount: Self.maximumSnapshotCommandOutputByteCount
        )
        guard succeededOrTruncated(numstatResult) else { throw .gitFailure }
        let untrackedResult = try run(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            repoRoot: scope.repoRoot,
            maximumOutputByteCount: Self.maximumSnapshotCommandOutputByteCount
        )
        guard succeededOrTruncated(untrackedResult) else { throw .gitFailure }

        var cappedSelection = WorkspaceChangesCappedFileSelection(
            maximumCount: Self.maximumFileCount
        )
        var trackedFileCount = 0
        parser.forEachNameStatusEntry(from: statusResult.output) { entry in
            trackedFileCount += 1
            cappedSelection.consider(WorkspaceChangedFile(
                path: entry.path,
                oldPath: entry.oldPath,
                status: entry.status,
                additions: 0,
                deletions: 0,
                isBinary: false
            ))
        }

        var untrackedFileCount = 0
        parser.forEachUntrackedPath(from: untrackedResult.output) { path in
            untrackedFileCount += 1
            cappedSelection.consider(WorkspaceChangedFile(
                path: path,
                oldPath: nil,
                status: .untracked,
                additions: 0,
                deletions: 0,
                isBinary: false
            ))
        }

        let cappedFiles = cappedSelection.files
        let cappedTrackedPaths = Set(
            cappedFiles.lazy.filter { $0.status != .untracked }.map(\.path)
        )
        var trackedAdditions = 0
        var trackedDeletions = 0
        var statsByPath: [String: WorkspaceChangesParser.NumstatEntry] = [:]
        statsByPath.reserveCapacity(cappedTrackedPaths.count)
        parser.forEachNumstatEntry(from: numstatResult.output) { entry in
            trackedAdditions += entry.additions
            trackedDeletions += entry.deletions
            if cappedTrackedPaths.contains(entry.path) {
                statsByPath[entry.path] = entry
            }
        }

        let cappedUntrackedPaths = cappedFiles.compactMap { file in
            file.status == .untracked ? file.path : nil
        }
        guard let inspectedUntrackedFiles = untrackedInspector.inspect(
            paths: cappedUntrackedPaths,
            repoRoot: scope.repoRoot
        ) else {
            throw .gitFailure
        }
        let untrackedByPath = Dictionary(
            uniqueKeysWithValues: inspectedUntrackedFiles.map { ($0.path, $0) }
        )
        var files: [WorkspaceChangedFile] = []
        files.reserveCapacity(cappedFiles.count)
        for cappedFile in cappedFiles {
            if cappedFile.status == .untracked {
                if let untracked = untrackedByPath[cappedFile.path] {
                    files.append(untracked)
                } else {
                    throw .gitFailure
                }
            } else {
                let stat = statsByPath[cappedFile.path]
                files.append(WorkspaceChangedFile(
                    path: cappedFile.path,
                    oldPath: cappedFile.oldPath,
                    status: cappedFile.status,
                    additions: stat?.additions ?? 0,
                    deletions: stat?.deletions ?? 0,
                    isBinary: stat?.isBinary ?? false
                ))
            }
        }

        let totalFileCount = trackedFileCount + untrackedFileCount
        let untrackedFiles = files.filter { $0.status == .untracked }
        return WorkspaceChangesSnapshot(
            scope: scope,
            files: files,
            totalFileCount: totalFileCount,
            additions: trackedAdditions
                + untrackedFiles.reduce(0) { $0 + $1.additions },
            deletions: trackedDeletions,
            truncated: totalFileCount > files.count
                || statusResult.standardOutputWasTruncated
                || numstatResult.standardOutputWasTruncated
                || untrackedResult.standardOutputWasTruncated
                || files.contains(where: \.isApproximate)
        )
    }

    private func resolveDefaultBranch(
        repoRoot: String
    ) throws(WorkspaceChangesServiceError) -> String? {
        if let symbolic = try output(
            arguments: ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            repoRoot: repoRoot,
            acceptedExitCodes: [0, 1]
        ) {
            return symbolic
        }
        for candidate in ["origin/main", "origin/master", "main", "master"] {
            let result = try run(
                ["rev-parse", "--verify", "--quiet", "\(candidate)^{commit}"],
                repoRoot: repoRoot
            )
            if result.exitCode == 0 { return candidate }
        }
        return nil
    }

    private func output(
        arguments: [String],
        repoRoot: String,
        acceptedExitCodes: Set<Int32>
    ) throws(WorkspaceChangesServiceError) -> String? {
        let result = try run(arguments, repoRoot: repoRoot)
        guard acceptedExitCodes.contains(result.exitCode) else { return nil }
        let trimmed = String(decoding: result.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func run(
        _ arguments: [String],
        repoRoot: String
    ) throws(WorkspaceChangesServiceError) -> WorkspaceChangesGitResult {
        do {
            return try runner.run(
                arguments: arguments,
                in: URL(fileURLWithPath: repoRoot, isDirectory: true)
            )
        } catch {
            throw .gitFailure
        }
    }

    private func run(
        _ arguments: [String],
        repoRoot: String,
        maximumOutputByteCount: Int
    ) throws(WorkspaceChangesServiceError) -> WorkspaceChangesGitResult {
        do {
            return try runner.run(
                arguments: arguments,
                in: URL(fileURLWithPath: repoRoot, isDirectory: true),
                maximumOutputByteCount: maximumOutputByteCount
            )
        } catch {
            throw .gitFailure
        }
    }

    private func succeededOrTruncated(_ result: WorkspaceChangesGitResult) -> Bool {
        result.exitCode == 0 || result.standardOutputWasTruncated
    }
}
