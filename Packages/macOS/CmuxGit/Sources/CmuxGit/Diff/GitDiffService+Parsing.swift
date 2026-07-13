internal import Foundation

extension GitDiffService {
    func maximumParsedPath(inNameStatusData data: Data) -> String? {
        parseChangedFiles(
            numstatData: nil,
            nameStatusData: data,
            untrackedData: nil
        ).files.map(\.path).max { lhs, rhs in
            gitPathPrecedes(lhs, rhs)
        }
    }

    func gitPathPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    func parseChangedFiles(
        numstatOutput: String?,
        nameStatusOutput: String?,
        untrackedOutput: String?
    ) -> [GitDiffSummary] {
        parseChangedFiles(
            numstatData: numstatOutput.map { Data($0.utf8) },
            nameStatusData: nameStatusOutput.map { Data($0.utf8) },
            untrackedData: untrackedOutput.map { Data($0.utf8) }
        ).files
    }

    func parseChangedFiles(
        numstatData: Data?,
        nameStatusData: Data?,
        untrackedData: Data?
    ) -> GitDiffParseResult {
        let numstatTokens = strictUTF8Tokens(numstatData)
        let nameStatusTokens = strictUTF8Tokens(nameStatusData)
        let untrackedTokens = strictUTF8Tokens(untrackedData)
        var partials: [String: GitDiffSummaryPartial] = [:]
        parseNumstatTokens(numstatTokens, into: &partials)
        parseNameStatusTokens(nameStatusTokens, into: &partials)
        parseUntrackedTokens(untrackedTokens, into: &partials)
        return GitDiffParseResult(
            files: partials.values
                .map(\.summary)
                .sorted { lhs, rhs in
                    lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
                },
            hasUndecodablePath: numstatTokens.contains(nil)
                || nameStatusTokens.contains(nil)
                || untrackedTokens.contains(nil)
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
                partials[status.path, default: GitDiffSummaryPartial(path: status.path)]
                    .apply(status: status.status, oldPath: status.oldPath)
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
