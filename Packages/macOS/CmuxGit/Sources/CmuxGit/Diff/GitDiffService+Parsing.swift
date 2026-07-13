internal import Foundation

extension GitDiffService {
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
        let numstatTokens = Self.strictUTF8Tokens(numstatData)
        let nameStatusTokens = Self.strictUTF8Tokens(nameStatusData)
        let untrackedTokens = Self.strictUTF8Tokens(untrackedData)
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
    private static func strictUTF8Tokens(_ output: Data?) -> [String?] {
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

private struct GitDiffSummaryPartial {
    let path: String
    var oldPath: String?
    var status: GitDiffStatus?
    var additions: Int?
    var deletions: Int?

    init(
        path: String,
        oldPath: String? = nil,
        status: GitDiffStatus? = nil,
        additions: Int? = nil,
        deletions: Int? = nil
    ) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }

    var summary: GitDiffSummary {
        GitDiffSummary(
            path: path,
            oldPath: oldPath,
            status: status ?? .modified,
            additions: additions,
            deletions: deletions
        )
    }

    mutating func apply(additions: Int?, deletions: Int?, oldPath: String?) {
        self.additions = additions
        self.deletions = deletions
        if let oldPath {
            self.oldPath = oldPath
        }
    }

    mutating func apply(status: GitDiffStatus, oldPath: String?) {
        self.status = status
        if let oldPath {
            self.oldPath = oldPath
        }
    }

    mutating func applyUntrackedReplacement() {
        status = .modified
        oldPath = nil
        additions = nil
        deletions = nil
    }
}

private struct GitDiffNumstatToken {
    let path: String
    let oldPath: String?
    let additions: Int?
    let deletions: Int?

    init?(token: String?, tokens: [String?], index: inout Int) {
        guard let token else { return nil }
        let pieces = token.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 3 else { return nil }
        additions = Int(pieces[0])
        deletions = Int(pieces[1])
        if pieces[2].isEmpty {
            guard index + 2 < tokens.count,
                  let decodedOldPath = tokens[index + 1],
                  let decodedPath = tokens[index + 2] else { return nil }
            oldPath = decodedOldPath
            path = decodedPath
            index += 3
        } else {
            oldPath = nil
            path = pieces[2]
            index += 1
        }
    }
}

private struct GitDiffNameStatusToken {
    let path: String
    let oldPath: String?
    let status: GitDiffStatus

    init?(token: String?, tokens: [String?], index: inout Int) {
        guard let token else { return nil }
        let pieces = token.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let statusRaw = pieces[0]
        guard let first = statusRaw.first else { return nil }
        switch first {
        case "A":
            status = .added
        case "M", "T", "U":
            status = .modified
        case "D":
            status = .deleted
        case "R":
            status = .renamed
        default:
            return nil
        }
        if status == .renamed {
            if pieces.count >= 3 {
                oldPath = pieces[1]
                path = pieces[2]
                index += 1
            } else {
                guard index + 2 < tokens.count,
                      let decodedOldPath = tokens[index + 1],
                      let decodedPath = tokens[index + 2] else { return nil }
                oldPath = decodedOldPath
                path = decodedPath
                index += 3
            }
        } else if pieces.count >= 2 {
            oldPath = nil
            path = pieces[1]
            index += 1
        } else {
            guard index + 1 < tokens.count,
                  let decodedPath = tokens[index + 1] else { return nil }
            oldPath = nil
            path = decodedPath
            index += 2
        }
    }
}
