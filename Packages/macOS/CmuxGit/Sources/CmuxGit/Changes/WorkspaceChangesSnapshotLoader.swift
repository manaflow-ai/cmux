import Foundation

/// Resolves Git scope and produces capped changed-file snapshots.
struct WorkspaceChangesSnapshotLoader: Sendable {
    static let maximumFileCount = 500
    static let maximumSnapshotCommandOutputByteCount = 32 * 1024 * 1024

    private let runner: any WorkspaceChangesGitRunning
    private let parser = WorkspaceChangesParser()
    private let untrackedInspector = WorkspaceUntrackedFileInspector()

    init(runner: any WorkspaceChangesGitRunning) {
        self.runner = runner
    }

    func resolveScope(forDirectory directory: String) -> WorkspaceChangesScope? {
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        guard let rootResult = try? runner.run(
            arguments: ["rev-parse", "--show-toplevel"],
            in: directoryURL
        ), rootResult.exitCode == 0 else { return nil }
        let repoRoot = String(decoding: rootResult.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repoRoot.isEmpty else { return nil }

        let branch = output(
            arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"],
            repoRoot: repoRoot,
            acceptedExitCodes: [0, 1]
        )
        let defaultRef = resolveDefaultBranch(repoRoot: repoRoot)
        let baseRef: String?
        let diffBase: String
        if let branch,
           let defaultRef,
           branch != defaultRef,
           defaultRef != "origin/\(branch)",
           let mergeBase = output(
               arguments: ["merge-base", "HEAD", defaultRef],
               repoRoot: repoRoot,
               acceptedExitCodes: [0]
           ) {
            baseRef = defaultRef
            diffBase = mergeBase
        } else {
            baseRef = nil
            diffBase = "HEAD"
        }
        guard let diffBaseCommitOID = output(
            arguments: ["rev-parse", "--verify", "\(diffBase)^{commit}"],
            repoRoot: repoRoot,
            acceptedExitCodes: [0]
        ) else { return nil }
        return WorkspaceChangesScope(
            repoRoot: repoRoot,
            branch: branch,
            baseRef: baseRef,
            diffBase: diffBase,
            diffBaseCommitOID: diffBaseCommitOID
        )
    }

    func loadSnapshot(scope: WorkspaceChangesScope) -> WorkspaceChangesSnapshot? {
        guard let statusResult = run(
            ["diff", "-M", "--name-status", "-z", scope.diffBase, "--"],
            repoRoot: scope.repoRoot,
            maximumOutputByteCount: Self.maximumSnapshotCommandOutputByteCount
        ), succeededOrTruncated(statusResult),
        let numstatResult = run(
            ["diff", "-M", "--numstat", "-z", scope.diffBase, "--"],
            repoRoot: scope.repoRoot,
            maximumOutputByteCount: Self.maximumSnapshotCommandOutputByteCount
        ), succeededOrTruncated(numstatResult),
        let untrackedResult = run(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            repoRoot: scope.repoRoot,
            maximumOutputByteCount: Self.maximumSnapshotCommandOutputByteCount
        ), succeededOrTruncated(untrackedResult) else { return nil }

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
            return nil
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
                    return nil
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
        )
    }

    private func resolveDefaultBranch(repoRoot: String) -> String? {
        if let symbolic = output(
            arguments: ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            repoRoot: repoRoot,
            acceptedExitCodes: [0, 1]
        ) {
            return symbolic
        }
        for candidate in ["origin/main", "origin/master", "main", "master"] {
            guard let result = run(
                ["rev-parse", "--verify", "--quiet", "\(candidate)^{commit}"],
                repoRoot: repoRoot
            ) else { return nil }
            if result.exitCode == 0 { return candidate }
        }
        return nil
    }

    private func output(
        arguments: [String],
        repoRoot: String,
        acceptedExitCodes: Set<Int32>
    ) -> String? {
        guard let result = run(arguments, repoRoot: repoRoot),
              acceptedExitCodes.contains(result.exitCode) else { return nil }
        let trimmed = String(decoding: result.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func run(_ arguments: [String], repoRoot: String) -> WorkspaceChangesGitResult? {
        try? runner.run(
            arguments: arguments,
            in: URL(fileURLWithPath: repoRoot, isDirectory: true)
        )
    }

    private func run(
        _ arguments: [String],
        repoRoot: String,
        maximumOutputByteCount: Int
    ) -> WorkspaceChangesGitResult? {
        try? runner.run(
            arguments: arguments,
            in: URL(fileURLWithPath: repoRoot, isDirectory: true),
            maximumOutputByteCount: maximumOutputByteCount
        )
    }

    private func succeededOrTruncated(_ result: WorkspaceChangesGitResult) -> Bool {
        result.exitCode == 0 || result.standardOutputWasTruncated
    }
}
