import Dispatch
import Foundation

extension SystemGitReferenceReader {
    private static let maximumDirectReferenceByteCount = 1 * 1_024 * 1_024
    private static let maximumDirectObjectIDByteCount = 128

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
        let configURLs = [
            URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("config"),
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("config"),
        ]
        for configURL in configURLs {
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

    func unreadableSnapshot(usesGitPlumbing: Bool = false) -> GitReferenceSnapshot {
        GitReferenceSnapshot(
            checkedOutBranch: .unreadable,
            headSignature: nil,
            currentCommit: nil,
            usesGitPlumbing: usesGitPlumbing
        )
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
        let effectiveDeadline = deadline
            ?? (DispatchTime.now() + GitMetadataSafetyConfiguration().gitStatusWallTime)
        guard effectiveDeadline > DispatchTime.now() else { return true }
        return boundedFileSnapshot(repository: repository, deadline: effectiveDeadline) == nil
    }

    /// Revalidates a normal files checkout without repeating backend discovery.
    func headSnapshot(
        repository: ResolvedGitRepository,
        deadline: DispatchTime?
    ) -> GitReferenceSnapshot {
        let effectiveDeadline = deadline
            ?? (DispatchTime.now() + GitMetadataSafetyConfiguration().gitStatusWallTime)
        guard let directSnapshot = boundedFileSnapshot(
            repository: repository,
            deadline: effectiveDeadline
        ) else {
            return snapshot(repository: repository, deadline: deadline)
        }
        // `.invalid` is Git's linked-worktree sentinel; resolve it through
        // plumbing instead of exposing the transient direct-file projection.
        guard directSnapshot.branchName != ".invalid" else {
            return snapshot(repository: repository, deadline: deadline)
        }
        return directSnapshot
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
                maximumByteCount: Self.maximumDirectObjectIDByteCount,
                deadline: deadline
            ) {
            case .contents(let contents, consumedByteCount: let byteCount):
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
        case .contents(let contents, consumedByteCount: let byteCount):
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

    /// Resolves bounded Git path hints for custom reference storage.
    func storageWatchPaths(
        repository: ResolvedGitRepository,
        runner: any WorkspaceChangesGitRunning,
        symbolicReference: String?,
        deadline: DispatchTime
    ) -> [String] {
        var paths: [String] = []
        var names = ["reftable", "packed-refs"]
        if let symbolicReference,
           symbolicReference.hasPrefix("refs/"),
           !symbolicReference.contains("..") {
            names.insert(symbolicReference, at: 0)
        }
        for name in names {
            guard paths.count < 8 else { break }
            guard let value = output(
                arguments: ["rev-parse", "--git-path", name],
                repository: repository,
                maximumByteCount: Self.maximumSymbolicReferenceByteCount,
                runner: runner,
                deadline: deadline
            ) else { continue }
            let path = value.hasPrefix("/")
                ? URL(fileURLWithPath: value).standardizedFileURL.path
                : URL(fileURLWithPath: repository.workTreeRoot)
                    .appendingPathComponent(value)
                    .standardizedFileURL.path
            let roots = [repository.gitDirectory, repository.commonDirectory, repository.workTreeRoot]
                .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            let isInRepository = roots.contains { root in
                path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
            if isInRepository {
                paths.append(name == "reftable"
                    ? URL(fileURLWithPath: path).appendingPathComponent("tables.list").path
                    : path)
            } else if name == "reftable" {
                appendExternalStorageWatchPath(
                    URL(fileURLWithPath: path).appendingPathComponent("tables.list"),
                    to: &paths,
                    deadline: deadline,
                    allowParentSentinel: false,
                    ancestorBoundary: nil
                )
            } else if name == "packed-refs" || name.hasPrefix("refs/") {
                let ancestorBoundary = externalReferenceStorageBoundary(
                    path: path,
                    referenceName: name
                )
                appendExternalStorageWatchPath(
                    URL(fileURLWithPath: path),
                    to: &paths,
                    deadline: deadline,
                    allowParentSentinel: name.hasPrefix("refs/") && ancestorBoundary != nil,
                    ancestorBoundary: ancestorBoundary
                )
            }
        }
        return paths
    }

    /// Runs one bounded plumbing command and returns trimmed UTF-8 output.
    func output(
        arguments: [String],
        repository: ResolvedGitRepository,
        maximumByteCount: Int,
        runner: any WorkspaceChangesGitRunning,
        deadline: DispatchTime
    ) -> String? {
        guard case .value(let value) = commandOutput(
            arguments: arguments,
            repository: repository,
            maximumByteCount: maximumByteCount,
            runner: runner,
            deadline: deadline
        ) else { return nil }
        return value
    }

    /// Runs one bounded command and preserves missing-vs-failed outcomes.
    func commandOutput(
        arguments: [String],
        repository: ResolvedGitRepository,
        maximumByteCount: Int,
        runner: any WorkspaceChangesGitRunning,
        deadline: DispatchTime
    ) -> GitReferenceCommandResult {
        let now = DispatchTime.now()
        guard deadline > now else { return .failed }
        let remainingNanoseconds = deadline.uptimeNanoseconds - now.uptimeNanoseconds
        let remainingSeconds = Double(remainingNanoseconds) / 1_000_000_000
        guard let result = try? runner.run(
            arguments: arguments,
            in: URL(fileURLWithPath: repository.workTreeRoot, isDirectory: true),
            maximumOutputByteCount: maximumByteCount,
            wallTimeLimit: remainingSeconds
        ),
        !result.standardOutputWasTruncated,
        let output = String(data: result.output, encoding: .utf8) else {
            return .failed
        }
        guard result.exitCode == 0 else {
            return result.exitCode == 1 ? .missing : .failed
        }
        guard let normalized = GitMetadataService.normalizedBranchName(output) else {
            return .failed
        }
        return .value(normalized)
    }

    /// Watches an existing external ref file, or its nearest existing local
    /// ancestor within the configured store boundary.
    private func appendExternalStorageWatchPath(
        _ targetURL: URL,
        to paths: inout [String],
        deadline: DispatchTime,
        allowParentSentinel: Bool,
        ancestorBoundary: String?
    ) {
        let target = targetURL.standardizedFileURL
        if let ancestorBoundary,
           !isSameOrInside(target.path, root: ancestorBoundary) {
            return
        }
        if configReader.isLocalRegularFile(at: target, deadline: deadline) {
            paths.append(target.path)
            return
        }
        guard allowParentSentinel else { return }
        var parent = target.deletingLastPathComponent()
        for _ in 0..<16 {
            if let ancestorBoundary,
               !isSameOrInside(parent.path, root: ancestorBoundary) {
                return
            }
            if configReader.isLocalDirectory(at: parent, deadline: deadline) {
                paths.append(parent.path)
                return
            }
            let next = parent.deletingLastPathComponent()
            guard next.path != parent.path else { return }
            parent = next
        }
    }

    private func externalReferenceStorageBoundary(
        path: String,
        referenceName: String
    ) -> String? {
        guard referenceName.hasPrefix("refs/"),
              path.hasSuffix(referenceName) else {
            return nil
        }
        let referenceStart = path.index(path.endIndex, offsetBy: -referenceName.count)
        let prefix = path[..<referenceStart]
        guard prefix.hasSuffix("/") else { return nil }
        let boundary = String(prefix.dropLast())
        return boundary == "/" || boundary.isEmpty ? nil : boundary
    }

    private func isSameOrInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

}
