internal import Foundation

extension WorkspaceChangesService {
    /// Reads a progressively bounded unified diff for one changed repository-relative path.
    ///
    /// Absolute paths and paths that escape the repository root lexically or
    /// through symlinks are rejected before the path reaches Git. Output is
    /// capped at 400 KiB or 6,000 lines at a complete-hunk boundary by
    /// default. A requested line budget scales the byte budget proportionally,
    /// up to the 1,000,000-line guard and 6 MiB response budget.
    ///
    /// If the current file's identity-bearing filesystem fingerprint changes while Git
    /// captures the diff, the capture is retried once. A second unstable
    /// capture fails instead of publishing content from an unpinned revision.
    ///
    /// - Parameters:
    ///   - directory: An absolute workspace directory to inspect.
    ///   - path: A repository-relative path from the current changes snapshot.
    ///   - maxLines: Optional progressive line budget. Values are clamped to
    ///     the default minimum and response abuse guard.
    /// - Returns: The file's metadata and bounded unified diff.
    /// - Throws: ``WorkspaceChangesServiceError`` when validation or Git fails.
    public nonisolated func fileDiff(
        forDirectory directory: String,
        path: String,
        maxLines: Int? = nil
    ) async throws -> WorkspaceFileDiff {
        let loaded = try await loadedScopeAndSnapshot(forDirectory: directory)
        let scope = loaded.scope
        let normalizedPath = try pathValidator.validatedPath(path, repoRoot: scope.repoRoot)
        let snapshot = loaded.snapshot
        guard let file = snapshot.files.first(where: { $0.path == normalizedPath }) else {
            throw WorkspaceChangesServiceError.fileNotChanged
        }
        if file.isBinary {
            return fileDiffValue(
                file: file,
                unifiedDiff: "",
                truncated: false,
                totalLineCount: 0,
                contentFingerprint: await currentContentFingerprint(
                    repoRoot: scope.repoRoot,
                    path: normalizedPath
                )
            )
        }

        let arguments: [String]
        let acceptedExitCodes: Set<Int32>
        if file.status == .untracked {
            arguments = [
                "--literal-pathspecs", "diff", "--unified=3", "--no-index",
                "--", "/dev/null", normalizedPath,
            ]
            acceptedExitCodes = [0, 1]
        } else {
            arguments = [
                "--literal-pathspecs", "diff", "-M", "--unified=3",
                scope.diffBase, "--", normalizedPath,
            ]
            acceptedExitCodes = [0]
        }
        let truncator = WorkspaceDiffTruncator(requestedMaximumLines: maxLines)
        for attempt in 0..<2 {
            let fingerprintBefore = await currentContentFingerprint(
                repoRoot: scope.repoRoot,
                path: normalizedPath
            )
            guard let result = try? await offCooperativePool({ [runner] in
                try runner.run(
                    arguments: arguments,
                    in: URL(fileURLWithPath: scope.repoRoot, isDirectory: true),
                    maximumOutputByteCount: truncator.maximumInputBytes
                )
            }), acceptedExitCodes.contains(result.exitCode)
                || result.standardOutputWasTruncated else {
                throw WorkspaceChangesServiceError.gitFailure
            }
            let fingerprintAfter = await currentContentFingerprint(
                repoRoot: scope.repoRoot,
                path: normalizedPath
            )
            guard fingerprintBefore == fingerprintAfter else {
                if attempt == 0 { continue }
                throw WorkspaceChangesServiceError.gitFailure
            }
            let bounded = truncator.truncate(
                String(decoding: result.output, as: UTF8.self)
            )
            return fileDiffValue(
                file: file,
                unifiedDiff: bounded.text,
                truncated: bounded.truncated || result.standardOutputWasTruncated,
                totalLineCount: result.standardOutputWasTruncated
                    ? nil
                    : bounded.totalLineCount,
                contentFingerprint: fingerprintAfter
            )
        }
        throw WorkspaceChangesServiceError.gitFailure
    }

    private nonisolated func currentContentFingerprint(
        repoRoot: String,
        path: String
    ) async -> String? {
        await fingerprintReader.contentFingerprint(
            repoRoot: repoRoot,
            relativePath: path
        )
    }

}
