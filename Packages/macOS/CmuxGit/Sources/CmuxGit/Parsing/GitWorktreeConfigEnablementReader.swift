import Dispatch
import Foundation

/// Resolves `extensions.worktreeConfig` through a bounded config include walk.
nonisolated struct GitWorktreeConfigEnablementReader: Sendable {
    private static let maximumPathCount = 256
    private static let maximumByteCount = 8 * 1_024 * 1_024

    private let reader: GitConfigFileReader

    init(reader: GitConfigFileReader = GitConfigFileReader()) {
        self.reader = reader
    }

    func rootConfigURLs(
        repository: ResolvedGitRepository,
        deadline: DispatchTime? = nil,
        branchContext: GitConfigBranchContext = .fileBacked
    ) -> [URL] {
        let rootURLs = [
            URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("config"),
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("config"),
        ]
        let effectiveDeadline = deadline
            ?? (DispatchTime.now() + GitMetadataSafetyConfiguration().gitStatusWallTime)
        guard isEnabled(
            repository: repository,
            rootURLs: rootURLs,
            deadline: effectiveDeadline,
            branchContext: branchContext
        ) else {
            return rootURLs
        }
        let worktreeConfigURL = URL(fileURLWithPath: repository.gitDirectory)
            .appendingPathComponent("config.worktree")
        guard reader.read(
            at: worktreeConfigURL,
            maximumByteCount: 1,
            deadline: effectiveDeadline
        ).isAvailable else {
            return rootURLs
        }
        return rootURLs + [worktreeConfigURL]
    }

    func isEnabled(
        repository: ResolvedGitRepository,
        rootURLs: [URL],
        deadline: DispatchTime? = nil,
        branchContext: GitConfigBranchContext = .fileBacked
    ) -> Bool {
        var seenPaths: Set<String> = []
        var remainingPathCount = Self.maximumPathCount
        var remainingByteCount = Self.maximumByteCount
        var enabled = false
        var objectFormatSHA256 = false
        var failed = false
        let effectiveDeadline = deadline
            ?? (DispatchTime.now() + GitMetadataSafetyConfiguration().gitStatusWallTime)
        for rootURL in rootURLs {
            process(
                at: rootURL,
                repository: repository,
                seenPaths: &seenPaths,
                remainingPathCount: &remainingPathCount,
                remainingByteCount: &remainingByteCount,
                enabled: &enabled,
                objectFormatSHA256: &objectFormatSHA256,
                deadline: effectiveDeadline,
                branchContext: branchContext,
                readDeadline: effectiveDeadline,
                failed: &failed
            )
            if failed { return false }
        }
        return enabled
    }

    func isSHA256ObjectFormat(
        repository: ResolvedGitRepository,
        rootURLs: [URL],
        deadline: DispatchTime? = nil,
        branchContext: GitConfigBranchContext = .fileBacked
    ) -> Bool? {
        var seenPaths: Set<String> = []
        var remainingPathCount = Self.maximumPathCount
        var remainingByteCount = Self.maximumByteCount
        var enabled = false
        var objectFormatSHA256 = false
        var failed = false
        let effectiveDeadline = deadline
            ?? (DispatchTime.now() + GitMetadataSafetyConfiguration().gitStatusWallTime)
        for rootURL in rootURLs {
            process(
                at: rootURL,
                repository: repository,
                seenPaths: &seenPaths,
                remainingPathCount: &remainingPathCount,
                remainingByteCount: &remainingByteCount,
                enabled: &enabled,
                objectFormatSHA256: &objectFormatSHA256,
                deadline: effectiveDeadline,
                branchContext: branchContext,
                readDeadline: effectiveDeadline,
                failed: &failed
            )
            if failed { return nil }
        }
        return objectFormatSHA256
    }

    private func process(
        at rawURL: URL,
        repository: ResolvedGitRepository,
        seenPaths: inout Set<String>,
        remainingPathCount: inout Int,
        remainingByteCount: inout Int,
        enabled: inout Bool,
        objectFormatSHA256: inout Bool,
        deadline: DispatchTime?,
        branchContext: GitConfigBranchContext,
        readDeadline: DispatchTime,
        failed: inout Bool
    ) {
        let configURL = rawURL.standardizedFileURL
        guard seenPaths.insert(configURL.path).inserted else { return }
        guard remainingPathCount > 0, remainingByteCount > 0 else {
            failed = true
            return
        }
        if let deadline, deadline <= DispatchTime.now() {
            failed = true
            return
        }
        remainingPathCount -= 1
        let readLimit = min(remainingByteCount, GitConfigFileReader.defaultMaximumByteCount)
        switch reader.read(
            at: configURL,
            maximumByteCount: readLimit,
            deadline: readDeadline
        ) {
        case .missing:
            return
        case .oversized, .unavailable:
            failed = true
            return
        case .contents(let contents, consumedByteCount: let consumedByteCount):
            remainingByteCount = max(0, remainingByteCount - consumedByteCount)
            var inExtensionsSection = false
            var includeSection = false
            for rawLine in contents.split(whereSeparator: \.isNewline) {
                if let deadline, deadline <= DispatchTime.now() {
                    failed = true
                    return
                }
                let line = GitMetadataService.gitConfigLineRemovingInlineComment(String(rawLine))
                    .trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") && line.hasSuffix("]") {
                    let lowercased = line.lowercased()
                    inExtensionsSection = lowercased == "[extensions]"
                    if lowercased == "[include]" {
                        includeSection = true
                    } else if let condition = GitMetadataService.gitConfigIncludeIfCondition(
                        fromSectionHeader: line
                    ) {
                        includeSection = GitMetadataService.gitConfigIncludeIfConditionMatches(
                            condition,
                            repository: repository,
                            configURL: configURL,
                            branchContext: branchContext
                        )
                    } else {
                        includeSection = false
                    }
                    continue
                }
                let parts = line.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if inExtensionsSection,
                   !parts.isEmpty,
                   parts[0].lowercased() == "worktreeconfig" {
                    let value = parts.count == 1
                        ? "true"
                        : GitMetadataService.gitConfigUnquotedValue(parts[1]).lowercased()
                    enabled = ["true", "yes", "on", "1", "t", "y"].contains(value)
                }
                if inExtensionsSection,
                   parts.count == 2,
                   parts[0].lowercased() == "objectformat" {
                    objectFormatSHA256 = GitMetadataService.gitConfigUnquotedValue(parts[1])
                        .lowercased() == "sha256"
                }
                guard includeSection,
                      parts.count == 2,
                      parts[0].lowercased() == "path",
                      let includeURL = GitMetadataService.gitConfigIncludeURL(
                          fromPathValue: parts[1],
                          relativeTo: configURL
                      ) else {
                    continue
                }
                process(
                    at: includeURL,
                    repository: repository,
                    seenPaths: &seenPaths,
                    remainingPathCount: &remainingPathCount,
                    remainingByteCount: &remainingByteCount,
                    enabled: &enabled,
                    objectFormatSHA256: &objectFormatSHA256,
                    deadline: deadline,
                    branchContext: branchContext,
                    readDeadline: readDeadline,
                    failed: &failed
                )
                if failed { return }
            }
        }
    }

}
