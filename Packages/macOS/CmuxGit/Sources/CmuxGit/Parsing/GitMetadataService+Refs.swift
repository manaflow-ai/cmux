import Foundation

extension GitMetadataService {
    /// Normalizes a branch name for keying: trims whitespace and maps empty to
    /// `nil`. Public because both this package's PR matching and app-side
    /// branch bookkeeping key state by the same normalization.
    public nonisolated static func normalizedBranchName(_ branch: String?) -> String? {
        let trimmed = branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The current branch name from `HEAD` (`ref: refs/heads/<name>`), or `nil`
    /// for a detached HEAD or unreadable `HEAD`.
    nonisolated static func gitBranchName(repository: ResolvedGitRepository) -> String? {
        let headURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("HEAD")
        guard let contents = try? String(contentsOf: headURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchPrefix = "ref: refs/heads/"
        guard trimmed.hasPrefix(branchPrefix) else {
            return nil
        }
        let branch = String(trimmed.dropFirst(branchPrefix.count))
        return branch.isEmpty ? nil : branch
    }

    /// Classifies the repository's `HEAD` into a ``GitCheckedOutBranch``,
    /// keeping a legitimate non-branch checkout (detached commit, non-branch
    /// symbolic ref) distinct from a missing/unreadable/malformed `HEAD`.
    nonisolated static func gitCheckedOutBranch(repository: ResolvedGitRepository) -> GitCheckedOutBranch {
        let headURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("HEAD")
        guard let contents = try? String(contentsOf: headURL, encoding: .utf8) else {
            return .unreadable
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchPrefix = "ref: refs/heads/"
        if trimmed.hasPrefix(branchPrefix) {
            guard let branch = normalizedBranchName(String(trimmed.dropFirst(branchPrefix.count))) else {
                return .unreadable
            }
            return .branch(branch)
        }
        if trimmed.hasPrefix("ref: ") {
            return .detached
        }
        if isLikelyCommitSHA(trimmed) {
            return .detached
        }
        return .unreadable
    }

    /// Whether `value` looks like a full git object id (40-hex SHA-1 or
    /// 64-hex SHA-256).
    private nonisolated static func isLikelyCommitSHA(_ value: String) -> Bool {
        guard value.count == 40 || value.count == 64 else { return false }
        return value.allSatisfy(\.isHexDigit)
    }

    /// A signature of `HEAD` plus the commit it resolves to: the symbolic ref
    /// text and the resolved ref value joined, or the detached SHA directly.
    nonisolated static func gitHeadSignature(repository: ResolvedGitRepository) -> String? {
        let headURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("HEAD")
        guard let contents = try? String(contentsOf: headURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let refPrefix = "ref: "
        guard trimmed.hasPrefix(refPrefix) else {
            return trimmed.isEmpty ? nil : trimmed
        }

        let refName = String(trimmed.dropFirst(refPrefix.count))
        guard !refName.isEmpty else { return trimmed }
        let refValue = gitRefValue(repository: repository, refName: refName) ?? ""
        return "\(trimmed)\n\(refValue)"
    }

    /// Resolves a ref name to its value, checking the loose ref under the git
    /// and common directories, then `packed-refs`. A ref name is repo-controlled
    /// input from `HEAD`; names whose standardized path escapes the directory
    /// they are joined to (e.g. `../../outside`) are ignored rather than read.
    nonisolated static func gitRefValue(repository: ResolvedGitRepository, refName: String) -> String? {
        let lookups = [
            (base: repository.gitDirectory, refURL: URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent(refName)),
            (base: repository.commonDirectory, refURL: URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent(refName)),
        ]
        var seenPaths: Set<String> = []
        for (base, refURL) in lookups {
            let basePath = URL(fileURLWithPath: base).standardizedFileURL.path
            let path = refURL.standardizedFileURL.path
            guard path.hasPrefix(basePath + "/"),
                  seenPaths.insert(path).inserted,
                  let contents = try? String(contentsOf: refURL, encoding: .utf8) else {
                continue
            }
            let value = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }

        let packedRefsURL = URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("packed-refs")
        guard let packedRefs = try? String(contentsOf: packedRefsURL, encoding: .utf8) else {
            return nil
        }
        for rawLine in packedRefs.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("^") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, String(parts[1]) == refName else { continue }
            return String(parts[0])
        }
        return nil
    }

    /// The current commit SHA the repository's `HEAD` resolves to (40 lowercase
    /// hex chars), or `nil` if it cannot be resolved to a commit.
    nonisolated static func gitCurrentCommit(repository: ResolvedGitRepository) -> String? {
        let headURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("HEAD")
        guard let contents = try? String(contentsOf: headURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let refPrefix = "ref: "
        let value: String
        if trimmed.hasPrefix(refPrefix) {
            let refName = String(trimmed.dropFirst(refPrefix.count))
            guard !refName.isEmpty, let refValue = gitRefValue(repository: repository, refName: refName) else {
                return nil
            }
            value = refValue
        } else {
            value = trimmed
        }

        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 40,
              normalized.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return normalized
    }
}
