internal import Foundation

extension GitDiffService {
    /// Lists changed files relative to `HEAD`, including untracked files.
    ///
    /// - Parameters:
    ///   - repoRoot: Repository root.
    ///   - maxOutputBytes: Per-listing bound on git output. When a listing
    ///     reaches the bound its subprocess is terminated, the trailing
    ///     partial record is dropped, and the result is marked truncated, so
    ///     a workspace with an enormous change set cannot accumulate
    ///     unbounded memory.
    ///   - maxFiles: Maximum rows to prepare with snapshot tokens.
    /// - Returns: Changed-file summaries in path order with a truncation marker,
    ///   or `nil` when any required Git command fails or times out.
    public func changedFiles(
        repoRoot: String,
        maxOutputBytes: Int = 4 * 1024 * 1024,
        maxFiles: Int = 4_000
    ) -> GitChangedFiles? {
        guard case .success(let changed) = changedFilesResult(
            repoRoot: repoRoot,
            maxOutputBytes: maxOutputBytes,
            maxFiles: maxFiles
        ) else { return nil }
        return changed
    }

    /// Lists changed files while preserving timeout and execution failures for
    /// callers that present actionable errors.
    public func changedFilesResult(
        repoRoot: String,
        maxOutputBytes: Int = 4 * 1024 * 1024,
        maxFiles: Int = 4_000
    ) -> GitDiffQueryResult<GitChangedFiles> {
        withOperationDeadline {
            changedFilesResultWithinOperation(
                repoRoot: repoRoot,
                maxOutputBytes: maxOutputBytes,
                maxFiles: maxFiles
            )
        }
    }

    private func changedFilesResultWithinOperation(
        repoRoot: String,
        maxOutputBytes: Int,
        maxFiles: Int
    ) -> GitDiffQueryResult<GitChangedFiles> {
        guard maxOutputBytes > 0, maxFiles > 0 else { return .notFound }
        let baseline: String
        switch diffBaselineResult(in: repoRoot) {
        case .success(let value):
            baseline = value
        case .notFound:
            return .notFound
        case .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        let initialContext: SnapshotContext
        switch snapshotContextResult(repoRoot: repoRoot, baselineObjectID: baseline) {
        case .success(let value):
            initialContext = value
        case .notFound, .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        let initialListing: GitChangedFilesListing
        switch changedFilesListingResult(
            repoRoot: repoRoot,
            baseline: baseline,
            maxOutputBytes: maxOutputBytes
        ) {
        case .success(let listing):
            initialListing = listing
        case .notFound, .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        let numstat = initialListing.numstat
        let nameStatus = initialListing.nameStatus
        let unmerged = initialListing.unmerged
        let untracked = initialListing.untracked
        guard let numstatData = completeRecordData(numstat),
              let nameStatusData = completeRecordData(nameStatus),
              let unmergedData = completeRecordData(unmerged),
              !unmerged.capped,
              let untrackedData = completeRecordData(untracked) else { return .failed }
        let parsed = verifiedChangedFiles(
            numstatData: numstatData,
            nameStatusData: nameStatusData,
            unmergedData: unmergedData,
            untrackedData: untrackedData,
            numstatCapped: numstat.capped,
            nameStatusCapped: nameStatus.capped
        )
        // Git paths are byte identities, while the mobile protocol uses Swift
        // strings. Failing the snapshot is safer than silently dropping an
        // undecodable entry and claiming the visible list is complete.
        guard !parsed.hasUndecodablePath else { return .failed }
        guard let initialRawData = completeRecordData(initialListing.raw),
              let initialRawIdentities = rawDiffIdentities(
                initialRawData,
                allowTrailingIncompleteRecord: initialListing.raw.capped
              ) else { return .failed }
        let identityVerifiedFiles: [GitDiffSummary]
        if initialListing.raw.capped {
            identityVerifiedFiles = parsed.files.filter { summary in
                summary.status == .untracked || initialRawIdentities[summary.path] != nil
            }
        } else {
            guard parsed.files.allSatisfy({ summary in
                summary.status == .untracked || initialRawIdentities[summary.path] != nil
            }) else { return .failed }
            identityVerifiedFiles = parsed.files
        }
        let boundedFiles = Array(identityVerifiedFiles.prefix(maxFiles))
        let reachedFileLimit = boundedFiles.count < parsed.files.count
        guard !Task.isCancelled else { return .failed }
        let initialFileIdentities: [FileSystemIdentity]
        switch snapshotFileIdentitiesResult(repoRoot: repoRoot, summaries: boundedFiles) {
        case .success(let values):
            initialFileIdentities = values
        case .notFound, .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        let finalListing: GitChangedFilesListing
        switch changedFilesListingResult(
            repoRoot: repoRoot,
            baseline: baseline,
            maxOutputBytes: maxOutputBytes
        ) {
        case .success(let listing):
            finalListing = listing
        case .notFound, .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        guard initialListing.hasSameOutput(as: finalListing) else { return .failed }
        let semanticIdentities: [Data?]
        switch semanticIdentitiesResult(
            repoRoot: repoRoot,
            summaries: boundedFiles,
            rawIdentities: initialRawIdentities
        ) {
        case .success(let values):
            semanticIdentities = values
        case .notFound, .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        let finalContext: SnapshotContext
        switch snapshotContextResult(repoRoot: repoRoot, baselineObjectID: baseline) {
        case .success(let value):
            finalContext = value
        case .notFound, .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        guard finalContext == initialContext else { return .failed }
        let finalFileIdentities: [FileSystemIdentity]
        switch snapshotFileIdentitiesResult(repoRoot: repoRoot, summaries: boundedFiles) {
        case .success(let values):
            finalFileIdentities = values
        case .notFound, .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        guard finalFileIdentities == initialFileIdentities,
              let snapshotTokens = snapshotTokens(
            context: finalContext,
            summaries: boundedFiles,
            identities: finalFileIdentities,
            semanticIdentities: semanticIdentities
        ) else { return .failed }
        var snapshotFiles: [GitDiffSummary] = []
        snapshotFiles.reserveCapacity(boundedFiles.count)
        for (summary, token) in zip(boundedFiles, snapshotTokens) {
            guard !Task.isCancelled else { return .failed }
            snapshotFiles.append(
                GitDiffSummary(
                    path: summary.path,
                    oldPath: summary.oldPath,
                    status: summary.status,
                    additions: summary.additions,
                    deletions: summary.deletions,
                    snapshotToken: token
                )
            )
        }
        return .success(
            GitChangedFiles(
                files: snapshotFiles,
                truncated: numstat.capped
                    || nameStatus.capped
                    || untracked.capped
                    || initialListing.raw.capped
                    || reachedFileLimit
            )
        )
    }

    /// Drops the trailing partial NUL-separated record a byte cap can leave
    /// behind, so capped listings only contribute complete records.
    private func completeRecordData(_ result: GitProcessResult) -> Data? {
        guard let output = result.rawOutput else { return nil }
        guard result.capped else { return output }
        guard let lastNul = output.lastIndex(of: 0) else { return Data() }
        return Data(output[...lastNul])
    }
}
