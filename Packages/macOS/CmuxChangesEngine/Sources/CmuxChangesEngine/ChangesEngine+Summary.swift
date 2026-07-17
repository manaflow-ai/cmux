import Foundation

extension ChangesEngine {
    /// Summarizes tracked and untracked working-tree changes against a baseline.
    ///
    /// Tracked status and line statistics are batched across the repository, and
    /// all untracked file statistics are computed in-process.
    ///
    /// - Parameters:
    ///   - repoRoot: The repository root directory.
    ///   - base: The baseline to compare with the current working tree.
    ///   - ignoreWhitespace: Whether tracked diffs use Git's `-w` comparison.
    /// - Returns: Aggregate and per-file changes metadata.
    /// - Throws: ``ChangesEngineError`` when Git output or file content cannot be read.
    public func summary(
        repoRoot: String,
        base: ChangesBase,
        ignoreWhitespace: Bool
    ) async throws -> ChangesSummary {
        let resolved = try await resolveBase(repoRoot: repoRoot, base: base)
        let statusOutput = try await runGit(repoRoot: repoRoot, arguments: [
            "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=no",
        ])
        let statOutput = try await runGit(
            repoRoot: repoRoot,
            arguments: gitDiffArguments(
                baseRef: resolved.diffRef,
                ignoreWhitespace: ignoreWhitespace,
                options: ["--raw", "--numstat", "-z"]
            )
        )
        let patchOutput = try await runGit(
            repoRoot: repoRoot,
            arguments: gitDiffArguments(
                baseRef: resolved.diffRef,
                ignoreWhitespace: ignoreWhitespace,
                options: ["--patch", "--binary", "--full-index", "-z"]
            )
        )

        let tracked = try parseTrackedChanges(statOutput)
        let patchSections = splitPatchSections(patchOutput)
        guard tracked.count == patchSections.count else {
            throw ChangesEngineError.gitFailed(
                "tracked stats and patch section counts differ (\(tracked.count) vs \(patchSections.count))"
            )
        }

        var files: [ChangesFile] = []
        files.reserveCapacity(tracked.count)
        for (change, patch) in zip(tracked, patchSections) {
            let patchData = Data(patch.utf8)
            files.append(ChangesFile(
                path: change.path,
                oldPath: change.oldPath,
                status: change.status,
                additions: change.additions,
                deletions: change.deletions,
                isBinary: change.isBinary,
                isLarge: isLarge(
                    additions: change.additions,
                    deletions: change.deletions,
                    patchBytes: patchData.count
                ),
                patchDigest: sha256Hex(patchData)
            ))
        }

        for path in parseUntrackedPaths(statusOutput) {
            let url = try fileURL(repoRoot: repoRoot, path: path)
            guard let data = try? Data(contentsOf: url) else { continue }
            let isBinary = contentIsBinary(data) || String(data: data, encoding: .utf8) == nil
            let patch = try untrackedPatch(path: path, data: data, isBinary: isBinary)
            let patchData = Data(patch.utf8)
            let additions = isBinary ? 0 : textLines(String(decoding: data, as: UTF8.self)).lines.count
            files.append(ChangesFile(
                path: path,
                oldPath: nil,
                status: .untracked,
                additions: additions,
                deletions: 0,
                isBinary: isBinary,
                isLarge: isLarge(
                    additions: additions,
                    deletions: 0,
                    patchBytes: max(patchData.count, data.count)
                ),
                patchDigest: sha256Hex(patchData)
            ))
        }

        files.sort { $0.path < $1.path }
        let totals = ChangesTotals(
            files: files.count,
            additions: files.reduce(0) { $0 + $1.additions },
            deletions: files.reduce(0) { $0 + $1.deletions }
        )
        let returnedFiles = Array(files.prefix(Self.maximumSummaryFiles))
        return ChangesSummary(
            baseInfo: resolved.info,
            totals: totals,
            files: returnedFiles,
            truncatedFileCount: files.count - returnedFiles.count
        )
    }
}
