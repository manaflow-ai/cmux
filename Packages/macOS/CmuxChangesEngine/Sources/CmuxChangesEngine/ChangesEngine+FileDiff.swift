import Foundation

extension ChangesEngine {
    /// Returns one cursor-paged unified diff for a repository path.
    ///
    /// Rename and copy callers should pass both the new-side `path` and
    /// old-side `oldPath`; both are supplied as literal Git pathspecs.
    ///
    /// - Parameters:
    ///   - repoRoot: The repository root directory.
    ///   - base: The baseline to compare with the current working tree.
    ///   - path: The new-side repository-relative path.
    ///   - oldPath: The old-side path for a rename or copy.
    ///   - cursor: The opaque cursor returned by the preceding page.
    ///   - ignoreWhitespace: Whether tracked diffs use Git's `-w` comparison.
    /// - Returns: At most 4,000 rows plus a continuation cursor.
    /// - Throws: ``ChangesEngineError`` for invalid paths, cursors, or Git output.
    public func fileDiff(
        repoRoot: String,
        base: ChangesBase,
        path: String,
        oldPath: String?,
        cursor: String?,
        ignoreWhitespace: Bool
    ) async throws -> FileDiff {
        let path = try validatedRelativePath(path)
        let oldPath = try oldPath.map(validatedRelativePath)
        let resolved = try await resolveBase(repoRoot: repoRoot, base: base)
        let paths = oldPath.map { [$0, path] } ?? [path]
        let trackedPatch = try await runGit(
            repoRoot: repoRoot,
            arguments: gitDiffArguments(
                baseRef: resolved.diffRef,
                ignoreWhitespace: ignoreWhitespace,
                options: ["--patch", "--binary", "--full-index", "-z"],
                paths: paths
            )
        )

        let patch: String
        let isBinary: Bool
        let patchByteCount: Int
        if trackedPatch.isEmpty {
            let status = try await runGit(repoRoot: repoRoot, arguments: [
                "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=no", "--", path,
            ])
            guard parseUntrackedPaths(status).contains(path) else {
                throw ChangesEngineError.fileNotChanged(path)
            }
            let data = try Data(contentsOf: fileURL(repoRoot: repoRoot, path: path))
            isBinary = contentIsBinary(data) || String(data: data, encoding: .utf8) == nil
            patch = try untrackedPatch(path: path, data: data, isBinary: isBinary)
            patchByteCount = max(Data(patch.utf8).count, data.count)
        } else {
            patch = trackedPatch
            isBinary = patch.contains("GIT binary patch") || patch.contains("Binary files ")
            patchByteCount = Data(patch.utf8).count
        }

        let hunks = isBinary ? [] : try parseUnifiedDiff(patch)
        let lineChanges = hunks.reduce(0) { total, hunk in
            total + hunk.rows.reduce(0) { count, row in
                count + ((row.kind == .add || row.kind == .del) ? 1 : 0)
            }
        }
        let page = try pagedHunks(hunks, cursor: cursor)
        return FileDiff(
            hunks: page.hunks,
            isBinary: isBinary,
            tooLarge: isLarge(additions: lineChanges, deletions: 0, patchBytes: patchByteCount),
            nextCursor: page.next
        )
    }

    /// Reads one-based inclusive new-side context lines for hunk expansion.
    ///
    /// The current working-tree file is authoritative. When it no longer exists,
    /// the method reads the path's `HEAD` blob so deleted files remain expandable.
    ///
    /// - Parameters:
    ///   - repoRoot: The repository root directory.
    ///   - base: The baseline associated with the request; validated for consistency.
    ///   - path: The new-side repository-relative path.
    ///   - startLine: The first one-based line to return.
    ///   - endLine: The final one-based line to return.
    /// - Returns: The requested available text lines.
    /// - Throws: ``ChangesEngineError`` when the range, path, or text is invalid.
    public func contextLines(
        repoRoot: String,
        base: ChangesBase,
        path: String,
        startLine: Int,
        endLine: Int
    ) async throws -> [String] {
        guard startLine >= 1, endLine >= startLine else {
            throw ChangesEngineError.invalidPath("invalid line range")
        }
        _ = try await resolveBase(repoRoot: repoRoot, base: base)
        let path = try validatedRelativePath(path)
        let url = try fileURL(repoRoot: repoRoot, path: path)
        let text: String
        if let data = try? Data(contentsOf: url) {
            guard !contentIsBinary(data), let decoded = String(data: data, encoding: .utf8) else {
                throw ChangesEngineError.unreadableText(path)
            }
            text = decoded
        } else {
            text = try await runGit(repoRoot: repoRoot, arguments: ["cat-file", "blob", "HEAD:\(path)"])
        }
        let lines = textLines(text).lines
        guard startLine <= lines.count else { return [] }
        let lower = startLine - 1
        let upper = min(endLine, lines.count)
        return Array(lines[lower..<upper])
    }
}
