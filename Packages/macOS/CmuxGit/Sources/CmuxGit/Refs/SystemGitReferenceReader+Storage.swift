import Dispatch
import Foundation

extension SystemGitReferenceReader {
    private static let maximumDirectReferenceByteCount = 1 * 1_024 * 1_024

    enum QuickReferenceStorageProbe: Sendable {
        case complete(String?)
        case incomplete
    }

    /// Reads the root config prefix without trusting an incomplete include graph.
    func quickReferenceStorageName(
        repository: ResolvedGitRepository,
        deadline: DispatchTime?
    ) -> QuickReferenceStorageProbe {
        var storageName: String?
        var hasInclude = false
        for configURL in GitMetadataService.gitRootConfigURLs(repository: repository) {
            if let deadline, deadline <= DispatchTime.now() { return .incomplete }
            switch configReader.read(
                at: configURL,
                maximumByteCount: 64 * 1_024,
                deadline: deadline
            ) {
            case .missing:
                continue
            case .oversized, .unavailable:
                return .incomplete
            case .contents(let contents, consumedByteCount: _):
                var inExtensionsSection = false
                var inIncludeSection = false
                for rawLine in contents.split(whereSeparator: \.isNewline) {
                    if let deadline, deadline <= DispatchTime.now() { return .incomplete }
                    let line = GitMetadataService.gitConfigLineRemovingInlineComment(String(rawLine))
                        .trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("[") && line.hasSuffix("]") {
                        let lowercased = line.lowercased()
                        inExtensionsSection = lowercased == "[extensions]"
                        inIncludeSection = lowercased == "[include]"
                            || lowercased.hasPrefix("[includeif ")
                        continue
                    }
                    let parts = line.split(separator: "=", maxSplits: 1).map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                    guard parts.count == 2 else { continue }
                    if inIncludeSection, parts[0].lowercased() == "path" {
                        hasInclude = true
                    }
                    if inExtensionsSection, parts[0].lowercased() == "refstorage" {
                        storageName = GitMetadataService.gitConfigUnquotedValue(parts[1]).lowercased()
                    }
                }
            }
        }
        return hasInclude ? .incomplete : .complete(storageName)
    }

    func unreadableSnapshot() -> GitReferenceSnapshot {
        GitReferenceSnapshot(checkedOutBranch: .unreadable, headSignature: nil, currentCommit: nil)
    }

    /// Reads file-backed refs through the same regular-file and byte bounds as config.
    func boundedFileSnapshot(
        repository: ResolvedGitRepository,
        deadline: DispatchTime
    ) -> GitReferenceSnapshot? {
        switch boundedReferenceRead(
            at: URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("HEAD"),
            maximumByteCount: Self.maximumSymbolicReferenceByteCount,
            deadline: deadline
        ) {
        case .missing:
            return unreadableSnapshot()
        case .oversized, .unavailable:
            return nil
        case .contents(let contents, consumedByteCount: _):
            let head = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !head.isEmpty else { return unreadableSnapshot() }
            if head.hasPrefix("ref: ") {
                let refName = String(head.dropFirst("ref: ".count))
                guard !refName.isEmpty else { return unreadableSnapshot() }
                let value: String?
                switch boundedReferenceValue(
                    repository: repository,
                    refName: refName,
                    deadline: deadline
                ) {
                case .oversized, .unavailable:
                    return nil
                case .missing:
                    value = nil
                case .contents(let contents, consumedByteCount: _):
                    value = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let branch: GitCheckedOutBranch
                if refName.hasPrefix("refs/heads/") {
                    guard let name = GitMetadataService.normalizedBranchName(
                        String(refName.dropFirst("refs/heads/".count))
                    ) else {
                        return unreadableSnapshot()
                    }
                    branch = .branch(name)
                } else {
                    branch = .detached
                }
                let signature = "\(head)\n\(value ?? "")"
                return GitReferenceSnapshot(
                    checkedOutBranch: branch,
                    headSignature: signature,
                    currentCommit: value.flatMap(normalizedObjectID)
                )
            }
            let currentCommit = normalizedObjectID(head)
            return GitReferenceSnapshot(
                checkedOutBranch: currentCommit == nil ? .unreadable : .detached,
                headSignature: head,
                currentCommit: currentCommit
            )
        }
    }

    func fileSnapshotRequiresPlumbing(
        repository: ResolvedGitRepository,
        deadline: DispatchTime?
    ) -> Bool {
        guard let deadline, deadline > DispatchTime.now() else { return true }
        return boundedFileSnapshot(repository: repository, deadline: deadline) == nil
    }

    /// Accepts only complete SHA-1 or SHA-256 object IDs.
    func normalizedObjectID(_ value: String) -> String? {
        let normalized = value.lowercased()
        guard normalized.count == 40 || normalized.count == 64,
              normalized.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return normalized
    }

    private func boundedReferenceValue(
        repository: ResolvedGitRepository,
        refName: String,
        deadline: DispatchTime
    ) -> GitConfigFileReader.ReadResult {
        let lookups = [repository.gitDirectory, repository.commonDirectory].map { base in
            (base: base, url: URL(fileURLWithPath: base).appendingPathComponent(refName))
        }
        var seenPaths: Set<String> = []
        for lookup in lookups {
            let refURL = lookup.url
            let basePath = URL(fileURLWithPath: lookup.base).standardizedFileURL.path
            let path = refURL.standardizedFileURL.path
            guard path.hasPrefix(basePath + "/"), seenPaths.insert(path).inserted else { continue }
            switch boundedReferenceRead(
                at: refURL,
                maximumByteCount: Self.maximumObjectIDByteCount,
                deadline: deadline
            ) {
            case .contents(let contents, consumedByteCount: byteCount):
                return .contents(contents, consumedByteCount: byteCount)
            case .missing:
                continue
            case .oversized:
                return .oversized(consumedByteCount: 0)
            case .unavailable(let byteCount):
                return .unavailable(consumedByteCount: byteCount)
            }
        }

        let packedURL = URL(fileURLWithPath: repository.commonDirectory)
            .appendingPathComponent("packed-refs")
        switch boundedReferenceRead(
            at: packedURL,
            maximumByteCount: Self.maximumDirectReferenceByteCount,
            deadline: deadline
        ) {
        case .missing:
            return .missing
        case .oversized, .unavailable:
            return .unavailable(consumedByteCount: 0)
        case .contents(let contents, consumedByteCount: byteCount):
            for rawLine in contents.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("^") else { continue }
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count == 2, String(parts[1]) == refName else { continue }
                return .contents(String(parts[0]), consumedByteCount: byteCount)
            }
            return .missing
        }
    }

    private func boundedReferenceRead(
        at url: URL,
        maximumByteCount: Int,
        deadline: DispatchTime
    ) -> GitConfigFileReader.ReadResult {
        guard deadline > DispatchTime.now() else {
            return .unavailable(consumedByteCount: 0)
        }
        return configReader.read(
            at: url,
            maximumByteCount: maximumByteCount,
            deadline: deadline
        )
    }

    /// Resolves the configured backend through the bounded include traversal.
    func referenceStorageName(
        repository: ResolvedGitRepository,
        branchContext: GitConfigBranchContext,
        deadline: DispatchTime? = nil
    ) -> String? {
        GitConfigBranchTraversal(
            repository: repository,
            branchContext: branchContext,
            configReader: configReader,
            deadline: deadline
        ).referenceStorageName()
    }

}
