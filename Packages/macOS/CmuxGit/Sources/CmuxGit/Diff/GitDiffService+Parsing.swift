internal import Foundation

extension GitDiffService {
    func parseChangedFiles(
        numstatOutput: String?,
        nameStatusOutput: String?,
        unmergedOutput: String? = nil,
        untrackedOutput: String?
    ) -> [GitDiffSummary] {
        parseChangedFiles(
            numstatData: numstatOutput.map { Data($0.utf8) },
            nameStatusData: nameStatusOutput.map { Data($0.utf8) },
            unmergedData: unmergedOutput.map { Data($0.utf8) },
            untrackedData: untrackedOutput.map { Data($0.utf8) }
        ).files
    }

    func parseChangedFiles(
        numstatData: Data?,
        nameStatusData: Data?,
        unmergedData: Data? = nil,
        untrackedData: Data?
    ) -> GitDiffParseResult {
        let numstatTokens = strictUTF8Tokens(numstatData)
        let nameStatusTokens = strictUTF8Tokens(nameStatusData)
        let unmergedTokens = strictUTF8Tokens(unmergedData)
        let untrackedTokens = strictUTF8Tokens(untrackedData)
        var partials: [String: GitDiffSummaryPartial] = [:]
        parseNumstatTokens(numstatTokens, into: &partials)
        parseNameStatusTokens(nameStatusTokens, into: &partials)
        parseUntrackedTokens(untrackedTokens, into: &partials)
        for case let path? in unmergedTokens {
            partials.removeValue(forKey: path)
        }
        return GitDiffParseResult(
            files: partials.values
                .map(\.summary)
                .sorted { lhs, rhs in
                    lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
                },
            hasUndecodablePath: numstatTokens.contains(nil)
                || nameStatusTokens.contains(nil)
                || unmergedTokens.contains(nil)
                || untrackedTokens.contains(nil)
        )
    }

    /// Merges independently bounded tracked listings only where both commands
    /// supplied the row metadata. Pure untracked rows are withheld when either
    /// tracked listing is capped because a missing tracked half could otherwise
    /// turn that row into a replacement or rename-source shape.
    func verifiedChangedFiles(
        numstatData: Data,
        nameStatusData: Data,
        unmergedData: Data,
        untrackedData: Data,
        numstatCapped: Bool,
        nameStatusCapped: Bool
    ) -> GitDiffParseResult {
        let combined = parseChangedFiles(
            numstatData: numstatData,
            nameStatusData: nameStatusData,
            unmergedData: unmergedData,
            untrackedData: untrackedData
        )
        let numstat = parseChangedFiles(
            numstatData: numstatData,
            nameStatusData: nil,
            unmergedData: unmergedData,
            untrackedData: nil
        )
        let nameStatus = parseChangedFiles(
            numstatData: nil,
            nameStatusData: nameStatusData,
            unmergedData: unmergedData,
            untrackedData: nil
        )
        let numstatByPath = Dictionary(uniqueKeysWithValues: numstat.files.map { ($0.path, $0) })
        let nameStatusByPath = Dictionary(uniqueKeysWithValues: nameStatus.files.map { ($0.path, $0) })
        let verified = combined.files.filter { summary in
            let numstatSummary = numstatByPath[summary.path]
            let nameStatusSummary = nameStatusByPath[summary.path]
            if numstatSummary != nil || nameStatusSummary != nil {
                guard let numstatSummary, let nameStatusSummary else { return false }
                return numstatSummary.oldPath == nameStatusSummary.oldPath
            }
            return !numstatCapped && !nameStatusCapped
        }
        return GitDiffParseResult(
            files: verified,
            hasUndecodablePath: combined.hasUndecodablePath
                || numstat.hasUndecodablePath
                || nameStatus.hasUndecodablePath
        )
    }

    /// Git paths are byte identities. Decode each NUL-delimited field strictly
    /// and retain a `nil` slot for unsupported bytes so a malformed rename
    /// cannot shift later fields into the wrong path position.
    private func strictUTF8Tokens(_ output: Data?) -> [String?] {
        guard let output, !output.isEmpty else { return [] }
        var fields = output.split(separator: 0, omittingEmptySubsequences: false)
        if output.last == 0, fields.last?.isEmpty == true {
            fields.removeLast()
        }
        return fields.map { String(data: Data($0), encoding: .utf8) }
    }

    private func parseNumstatTokens(_ tokens: [String?], into partials: inout [String: GitDiffSummaryPartial]) {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if let numstat = GitDiffNumstatToken(token: token, tokens: tokens, index: &index) {
                partials[numstat.path, default: GitDiffSummaryPartial(path: numstat.path)]
                    .apply(additions: numstat.additions, deletions: numstat.deletions, oldPath: numstat.oldPath)
                continue
            }
            index += 1
        }
    }

    private func parseNameStatusTokens(_ tokens: [String?], into partials: inout [String: GitDiffSummaryPartial]) {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if let status = GitDiffNameStatusToken(token: token, tokens: tokens, index: &index) {
                if status.isUnmerged {
                    // Git emits combined `diff --cc` sections for unmerged
                    // paths, which this two-way mobile parser cannot render.
                    // Withhold the row instead of advertising a diff that can
                    // only fail and refresh indefinitely when selected.
                    partials.removeValue(forKey: status.path)
                } else {
                    partials[status.path, default: GitDiffSummaryPartial(path: status.path)]
                        .apply(status: status.status, oldPath: status.oldPath)
                }
                continue
            }
            index += 1
        }
    }

    private func parseUntrackedTokens(_ paths: [String?], into partials: inout [String: GitDiffSummaryPartial]) {
        for case let path? in paths {
            if var partial = partials[path], partial.status == .deleted {
                partial.applyUntrackedReplacement()
                partials[path] = partial
            } else if partials[path] == nil {
                partials[path] = GitDiffSummaryPartial(path: path, status: .untracked)
            }
        }
    }
}

struct GitDiffParseResult {
    let files: [GitDiffSummary]
    let hasUndecodablePath: Bool
}
