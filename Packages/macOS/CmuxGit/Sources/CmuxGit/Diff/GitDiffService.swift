import CmuxFoundation
public import Foundation

/// Runs git commands needed by the mobile diff-review flow.
public struct GitDiffService: Sendable {
    private static let nonLockingGitEnvironmentKey = "GIT_OPTIONAL_LOCKS"
    private static let nonLockingGitEnvironmentValue = "0"

    private let gitExecutableURL: URL
    private let environment: [String: String]

    /// Creates a git diff service.
    ///
    /// - Parameters:
    ///   - gitExecutableURL: Git executable URL.
    ///   - environment: Base process environment.
    public init(
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.gitExecutableURL = gitExecutableURL
        self.environment = environment
    }

    /// Resolves the enclosing repository root for a directory.
    ///
    /// - Parameter directory: Directory inside a git repository.
    /// - Returns: Repository root, or `nil` when `directory` is not in a repo.
    public func repositoryRoot(for directory: String) -> String? {
        runGit(in: directory, arguments: ["rev-parse", "--show-toplevel"]).successOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lists changed files relative to `HEAD`, including untracked files.
    ///
    /// - Parameter repoRoot: Repository root.
    /// - Returns: Changed-file summaries in path order.
    public func changedFiles(repoRoot: String) -> [GitDiffSummary] {
        let numstat = runGit(
            in: repoRoot,
            arguments: ["diff", "HEAD", "--numstat", "-z", "--no-color", "--find-renames"]
        ).successOutput
        let nameStatus = runGit(
            in: repoRoot,
            arguments: ["diff", "HEAD", "--name-status", "-z", "--no-color", "--find-renames"]
        ).successOutput
        let untracked = runGit(
            in: repoRoot,
            arguments: ["ls-files", "--others", "--exclude-standard", "-z"]
        ).successOutput
        return parseChangedFiles(numstatOutput: numstat, nameStatusOutput: nameStatus, untrackedOutput: untracked)
    }

    /// Reads a unified diff for one repository-relative file path.
    ///
    /// - Parameters:
    ///   - repoRoot: Repository root.
    ///   - path: Repository-relative path.
    /// - Returns: Raw one-file unified diff, or `nil` when git fails.
    public func fileDiff(repoRoot: String, path: String) -> GitFileDiff? {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else { return nil }
        if isUntracked(repoRoot: repoRoot, path: normalizedPath) {
            let result = runGit(
                in: repoRoot,
                arguments: ["diff", "--no-index", "--no-color", "/dev/null", normalizedPath],
                acceptedTerminationStatuses: [0, 1]
            )
            guard let output = result.successOutput else { return nil }
            return GitFileDiff(path: normalizedPath, unifiedDiff: output)
        }
        let result = runGit(
            in: repoRoot,
            arguments: ["diff", "HEAD", "--no-color", "--find-renames", "--", normalizedPath]
        )
        guard let output = result.successOutput else { return nil }
        return GitFileDiff(path: normalizedPath, unifiedDiff: output)
    }

    func parseChangedFiles(numstatOutput: String?, nameStatusOutput: String?, untrackedOutput: String?) -> [GitDiffSummary] {
        var partials: [String: GitDiffSummaryPartial] = [:]
        parseNumstatOutput(numstatOutput, into: &partials)
        parseNameStatusOutput(nameStatusOutput, into: &partials)
        parseUntrackedOutput(untrackedOutput, into: &partials)
        return partials.values
            .map(\.summary)
            .sorted { lhs, rhs in lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending }
    }

    private func parseNumstatOutput(_ output: String?, into partials: inout [String: GitDiffSummaryPartial]) {
        guard let output, !output.isEmpty else { return }
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
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

    private func parseNameStatusOutput(_ output: String?, into partials: inout [String: GitDiffSummaryPartial]) {
        guard let output, !output.isEmpty else { return }
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
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

    private func parseUntrackedOutput(_ output: String?, into partials: inout [String: GitDiffSummaryPartial]) {
        guard let output, !output.isEmpty else { return }
        let paths = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        for path in paths where partials[path] == nil {
            partials[path] = GitDiffSummaryPartial(path: path, status: .untracked)
        }
    }

    private func isUntracked(repoRoot: String, path: String) -> Bool {
        let output = runGit(
            in: repoRoot,
            arguments: ["ls-files", "--others", "--exclude-standard", "-z", "--", path]
        ).successOutput
        return output?.split(separator: "\0", omittingEmptySubsequences: true).contains(Substring(path)) == true
    }

    private func runGit(
        in directory: String,
        arguments: [String],
        acceptedTerminationStatuses: Set<Int32> = [0]
    ) -> GitProcessResult {
        let process = Process()
        process.executableURL = gitExecutableURL
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = nonLockingGitEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            process.waitUntilExit()
            guard acceptedTerminationStatuses.contains(process.terminationStatus) else {
                return GitProcessResult(output: nil)
            }
            return GitProcessResult(output: String(data: data, encoding: .utf8))
        } catch {
            return GitProcessResult(output: nil)
        }
    }

    private func nonLockingGitEnvironment() -> [String: String] {
        var environment = environment
        environment[Self.nonLockingGitEnvironmentKey] = Self.nonLockingGitEnvironmentValue
        return environment
    }
}

private struct GitProcessResult {
    let output: String?

    var successOutput: String? {
        output
    }
}

private struct GitDiffSummaryPartial {
    let path: String
    var oldPath: String?
    var status: GitDiffStatus?
    var additions: Int?
    var deletions: Int?

    init(path: String, oldPath: String? = nil, status: GitDiffStatus? = nil, additions: Int? = nil, deletions: Int? = nil) {
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
}

private struct GitDiffNumstatToken {
    let path: String
    let oldPath: String?
    let additions: Int?
    let deletions: Int?

    init?(token: String, tokens: [String], index: inout Int) {
        let pieces = token.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 3 else { return nil }
        additions = Int(pieces[0])
        deletions = Int(pieces[1])
        if pieces[2].isEmpty {
            guard index + 2 < tokens.count else { return nil }
            oldPath = tokens[index + 1]
            path = tokens[index + 2]
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

    init?(token: String, tokens: [String], index: inout Int) {
        let pieces = token.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let statusRaw = pieces[0]
        guard let first = statusRaw.first else { return nil }
        switch first {
        case "A":
            status = .added
        case "M", "T":
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
                guard index + 2 < tokens.count else { return nil }
                oldPath = tokens[index + 1]
                path = tokens[index + 2]
                index += 3
            }
        } else if pieces.count >= 2 {
            oldPath = nil
            path = pieces[1]
            index += 1
        } else {
            guard index + 1 < tokens.count else { return nil }
            oldPath = nil
            path = tokens[index + 1]
            index += 2
        }
    }
}
