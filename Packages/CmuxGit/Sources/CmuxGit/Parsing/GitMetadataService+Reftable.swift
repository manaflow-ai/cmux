import Foundation
internal import CmuxProcess

extension GitMetadataService {
    private static let reftableGitCommandTimeout: TimeInterval = 5

    /// Whether this repository stores refs in git's reftable backend.
    ///
    /// Reftable worktrees can have a placeholder `HEAD` file such as
    /// `ref: refs/heads/.invalid`; the real symbolic ref lives in the reftable
    /// data. Fall back to `git` for those repositories rather than rendering the
    /// placeholder as a branch name in the sidebar.
    nonisolated static func repositoryUsesReftable(repository: ResolvedGitRepository) -> Bool {
        gitConfigValue(repository: repository, section: "extensions", key: "refStorage")?
            .caseInsensitiveCompare("reftable") == .orderedSame
    }

    nonisolated static func gitCLIReftableMetadata(
        repository: ResolvedGitRepository,
        commands: any CommandRunning
    ) async -> (branch: String?, isDirty: Bool?, headSignature: String?) {
        async let fullRef = gitCLIOutput(
            repository: repository,
            commands: commands,
            arguments: ["symbolic-ref", "--quiet", "HEAD"]
        )
        async let commit = gitCLIOutput(
            repository: repository,
            commands: commands,
            arguments: ["rev-parse", "--verify", "HEAD"]
        )
        async let status = gitCLIOutput(
            repository: repository,
            commands: commands,
            arguments: ["status", "--porcelain", "--untracked-files=no"]
        )

        let ref = await trimmedNonEmpty(fullRef)
        let branch = normalizedBranchName(shortBranchName(fromFullRef: ref))
        let commitValue = await trimmedNonEmpty(commit)
        let statusValue = await status

        let headSignature: String? = {
            if let ref {
                return commitValue.map { "ref: \(ref)\n\($0)" } ?? "ref: \(ref)"
            }
            return commitValue
        }()

        return (
            branch: branch,
            isDirty: statusValue.map { !$0.isEmpty },
            headSignature: headSignature
        )
    }

    private nonisolated static func gitCLIOutput(
        repository: ResolvedGitRepository,
        commands: any CommandRunning,
        arguments: [String]
    ) async -> String? {
        await commands.runStandardOutput(
            directory: repository.workTreeRoot,
            executable: "git",
            arguments: arguments,
            timeout: reftableGitCommandTimeout
        )
    }

    private nonisolated static func shortBranchName(fromFullRef ref: String?) -> String? {
        let prefix = "refs/heads/"
        guard let ref, ref.hasPrefix(prefix) else { return nil }
        return String(ref.dropFirst(prefix.count))
    }

    private nonisolated static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func gitConfigValue(
        repository: ResolvedGitRepository,
        section targetSection: String,
        key targetKey: String
    ) -> String? {
        let targetSection = targetSection.lowercased()
        let targetKey = targetKey.lowercased()
        var value: String?

        for configURL in gitConfigURLs(repository: repository) {
            guard let config = try? String(contentsOf: configURL, encoding: .utf8) else {
                continue
            }

            var inTargetSection = false
            for rawLine in config.components(separatedBy: .newlines) {
                let line = gitConfigLineRemovingInlineComment(rawLine)
                    .trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }

                if let section = gitConfigSectionName(fromHeader: line) {
                    inTargetSection = section == targetSection
                    continue
                }

                guard inTargetSection else { continue }
                let parts = line.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard parts.count == 2, parts[0].lowercased() == targetKey else {
                    continue
                }

                value = gitConfigUnquotedValue(parts[1])
            }
        }

        return trimmedNonEmpty(value)
    }

    private nonisolated static func gitConfigSectionName(fromHeader line: String) -> String? {
        guard line.hasPrefix("["), line.hasSuffix("]") else { return nil }
        let body = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        let name = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? body
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }
}
