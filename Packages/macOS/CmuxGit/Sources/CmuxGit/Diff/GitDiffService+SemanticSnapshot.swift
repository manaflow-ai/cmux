internal import Foundation

extension GitDiffService {
    func rawDiffIdentities(
        _ output: Data,
        allowTrailingIncompleteRecord: Bool = false
    ) -> [String: Data]? {
        guard !output.isEmpty else { return [:] }
        var fields = output.split(separator: 0, omittingEmptySubsequences: false)
        if output.last == 0, fields.last?.isEmpty == true {
            fields.removeLast()
        }
        var identities: [String: Data] = [:]
        var index = 0
        while index < fields.count {
            let header = fields[index]
            guard let headerText = String(data: Data(header), encoding: .utf8),
                  headerText.hasPrefix(":"),
                  let statusField = headerText.split(separator: " ").last,
                  let status = statusField.first else { return nil }
            index += 1
            let path: String
            var identity = Data(header)
            identity.append(0)
            if status == "R" || status == "C" {
                guard index + 1 < fields.count else {
                    return allowTrailingIncompleteRecord ? identities : nil
                }
                guard let oldPath = String(data: Data(fields[index]), encoding: .utf8),
                      let newPath = String(data: Data(fields[index + 1]), encoding: .utf8) else { return nil }
                path = newPath
                identity.append(contentsOf: oldPath.utf8)
                identity.append(0)
                identity.append(contentsOf: newPath.utf8)
                index += 2
            } else {
                guard index < fields.count else {
                    return allowTrailingIncompleteRecord ? identities : nil
                }
                guard let decodedPath = String(data: Data(fields[index]), encoding: .utf8) else { return nil }
                path = decodedPath
                identity.append(contentsOf: decodedPath.utf8)
                index += 1
            }
            guard identities.updateValue(identity, forKey: path) == nil else { return nil }
        }
        return identities
    }

    func rawDiffIdentityResult(
        repoRoot: String,
        baseline: String,
        summary: GitDiffSummary
    ) -> GitDiffQueryResult<Data?> {
        let result = runGit(
            in: repoRoot,
            arguments: [
                "diff", baseline, "--ignore-submodules=none", "-O/dev/null", "--raw", "--full-index",
                "-z", "--no-color", "--find-renames", "--no-ext-diff", "--no-textconv", "--",
            ] + snapshotValidationPathspecs(summary),
            maxOutputBytes: 64 * 1024
        )
        if let failure: GitDiffQueryResult<Data?> = queryFailure(from: result) {
            return failure
        }
        guard let output = result.rawOutput,
              !result.capped,
              let identities = rawDiffIdentities(output) else { return .failed }
        let identity = identities[summary.path]
        guard identity != nil || summary.status == .untracked else { return .notFound }
        if summary.status == .untracked, identity != nil {
            switch statusForUntrackedBaselineReplacement(
                repoRoot: repoRoot,
                baseline: baseline,
                path: summary.path,
                maxOutputBytes: 64 * 1024
            ) {
            case .success(.untracked):
                return .success(nil)
            case .success, .notFound:
                return .notFound
            case .failed:
                return .failed
            case .timedOut:
                return .timedOut
            }
        }
        guard let identity else { return .success(nil) }
        guard rawIdentityNeedsWorkingTreeHead(identity) else { return .success(identity) }
        switch gitlinkWorkingTreeStatesResult(repoRoot: repoRoot, paths: [summary.path]) {
        case .success(let states):
            return .success(combinedSemanticIdentity(raw: identity, gitlinkState: states[summary.path]))
        case .notFound, .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
    }

    func semanticIdentitiesResult(
        repoRoot: String,
        summaries: [GitDiffSummary],
        rawIdentities: [String: Data]
    ) -> GitDiffQueryResult<[Data?]> {
        let gitlinkPaths: [String] = summaries.compactMap { summary -> String? in
            guard let raw = rawIdentities[summary.path],
                  rawIdentityNeedsWorkingTreeHead(raw) else { return nil }
            return summary.path
        }
        let gitlinkStates: [String: String]
        switch gitlinkWorkingTreeStatesResult(repoRoot: repoRoot, paths: gitlinkPaths) {
        case .success(let values):
            gitlinkStates = values
        case .notFound, .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        var identities: [Data?] = []
        identities.reserveCapacity(summaries.count)
        for summary in summaries {
            guard let raw = rawIdentities[summary.path] else {
                guard summary.status == .untracked else { return .notFound }
                identities.append(nil)
                continue
            }
            identities.append(
                rawIdentityNeedsWorkingTreeHead(raw)
                    ? combinedSemanticIdentity(raw: raw, gitlinkState: gitlinkStates[summary.path])
                    : raw
            )
        }
        return .success(identities)
    }

    func currentSummaryMatchesResult(
        repoRoot: String,
        baseline: String,
        expected: GitDiffSummary
    ) -> GitDiffQueryResult<Bool> {
        let pathspecs = snapshotValidationPathspecs(expected)
        let numstat = runGit(
            in: repoRoot,
            arguments: [
                "diff", baseline, "--ignore-submodules=none", "-O/dev/null", "--numstat", "-z",
                "--no-color", "--find-renames", "--no-ext-diff", "--no-textconv", "--",
            ] + pathspecs,
            maxOutputBytes: 64 * 1024
        )
        if let failure: GitDiffQueryResult<Bool> = queryFailure(from: numstat) { return failure }
        let nameStatus = runGit(
            in: repoRoot,
            arguments: [
                "diff", baseline, "--ignore-submodules=none", "-O/dev/null", "--name-status", "-z",
                "--no-color", "--find-renames", "--no-ext-diff", "--no-textconv", "--",
            ] + pathspecs,
            maxOutputBytes: 64 * 1024
        )
        if let failure: GitDiffQueryResult<Bool> = queryFailure(from: nameStatus) { return failure }
        let untracked = runGit(
            in: repoRoot,
            arguments: [
                "ls-files", "--others", "--exclude-standard", "-z", "--",
                literalPathspec(expected.path), descendantExclusionPathspec(expected.path),
            ],
            maxOutputBytes: 64 * 1024
        )
        if let failure: GitDiffQueryResult<Bool> = queryFailure(from: untracked) { return failure }
        guard let numstatData = numstat.rawOutput,
              let nameStatusData = nameStatus.rawOutput,
              let untrackedData = untracked.rawOutput,
              !numstat.capped,
              !nameStatus.capped,
              !untracked.capped else { return .failed }
        let parsed = parseChangedFiles(
            numstatData: numstatData,
            nameStatusData: nameStatusData,
            untrackedData: untrackedData
        )
        guard !parsed.hasUndecodablePath else { return .failed }
        let matches = parsed.files.contains { current in
            current.path == expected.path
                && current.oldPath == expected.oldPath
                && current.status == expected.status
                && current.additions == expected.additions
                && current.deletions == expected.deletions
        }
        guard !matches, expected.status == .untracked,
              parsed.files.contains(where: {
                $0.path == expected.path && $0.status == .modified
              }) else { return .success(matches) }
        switch statusForUntrackedBaselineReplacement(
            repoRoot: repoRoot,
            baseline: baseline,
            path: expected.path,
            maxOutputBytes: 64 * 1024
        ) {
        case .success(let status):
            return .success(status == .untracked)
        case .notFound:
            return .success(false)
        case .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
    }

    private func snapshotValidationPathspecs(_ summary: GitDiffSummary) -> [String] {
        let paths = [summary.oldPath, summary.path].compactMap { $0 }
        return exactPathspecs(paths, excludingDescendantsOf: Set(paths))
    }

    func snapshotMatchesResult(
        _ expectedToken: String,
        repoRoot: String,
        baseline: String,
        summary: GitDiffSummary
    ) -> GitDiffQueryResult<Bool> {
        let context: SnapshotContext
        switch snapshotContextResult(repoRoot: repoRoot, baselineObjectID: baseline) {
        case .success(let value):
            context = value
        case .notFound, .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        switch currentSummaryMatchesResult(
            repoRoot: repoRoot,
            baseline: baseline,
            expected: summary
        ) {
        case .success(true):
            break
        case .success(false), .notFound:
            return .success(false)
        case .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        let identities: [FileSystemIdentity]
        switch snapshotFileIdentitiesResult(repoRoot: repoRoot, summaries: [summary]) {
        case .success(let value):
            identities = value
        case .notFound, .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        let semanticIdentity: Data?
        switch rawDiffIdentityResult(repoRoot: repoRoot, baseline: baseline, summary: summary) {
        case .success(let value):
            semanticIdentity = value
        case .notFound:
            return .success(false)
        case .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        guard let currentToken = snapshotTokens(
            context: context,
            summaries: [summary],
            identities: identities,
            semanticIdentities: [semanticIdentity]
        )?.first else { return .failed }
        return .success(currentToken == expectedToken)
    }

    func validatedSnapshotResult(
        _ diff: GitFileDiff,
        expectedToken: String?,
        expectedSummary: GitDiffSummary?,
        repoRoot: String
    ) -> GitDiffQueryResult<GitFileDiff> {
        guard let expectedToken, let expectedSummary else { return .success(diff) }
        let currentBaseline: String
        switch diffBaselineResult(in: repoRoot) {
        case .success(let value):
            currentBaseline = value
        case .notFound:
            return .notFound
        case .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
        switch snapshotMatchesResult(
            expectedToken,
            repoRoot: repoRoot,
            baseline: currentBaseline,
            summary: expectedSummary
        ) {
        case .success(true):
            return .success(diff)
        case .success(false), .notFound:
            return .notFound
        case .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
    }

    private func rawIdentityNeedsWorkingTreeHead(_ identity: Data) -> Bool {
        guard let separator = identity.firstIndex(of: 0),
              let header = String(data: identity[..<separator], encoding: .utf8) else { return false }
        let fields = header.split(separator: " ")
        guard fields.count >= 2 else { return false }
        return fields[0] == ":160000" || fields[1] == "160000"
    }

    private func gitlinkWorkingTreeStatesResult(
        repoRoot: String,
        paths: [String]
    ) -> GitDiffQueryResult<[String: String]> {
        guard !paths.isEmpty else { return .success([:]) }
        let maxOutputBytes = paths.reduce(1024) { $0 + $1.utf8.count + 72 }
        let result = processRunner.runGitlinkWorkingTreeStates(
            repoRoot: repoRoot,
            paths: paths,
            maxOutputBytes: maxOutputBytes,
            deadlineSeconds: remainingOperationDeadlineSeconds
        )
        if let failure: GitDiffQueryResult<[String: String]> = queryFailure(from: result) {
            return failure
        }
        guard let output = result.rawOutput, !result.capped else { return .failed }
        var fields = output.split(separator: 0, omittingEmptySubsequences: false)
        if output.last == 0, fields.last?.isEmpty == true {
            fields.removeLast()
        }
        guard fields.count == paths.count * 2 else { return .failed }
        var states: [String: String] = [:]
        var index = 0
        while index < fields.count {
            guard let path = String(data: Data(fields[index]), encoding: .utf8),
                  let state = String(data: Data(fields[index + 1]), encoding: .utf8),
                  states.updateValue(state, forKey: path) == nil else { return .failed }
            index += 2
        }
        return .success(states)
    }

    private func combinedSemanticIdentity(raw: Data, gitlinkState: String?) -> Data {
        var identity = raw
        identity.append(0)
        if let gitlinkState {
            identity.append(contentsOf: gitlinkState.utf8)
        }
        return identity
    }
}
