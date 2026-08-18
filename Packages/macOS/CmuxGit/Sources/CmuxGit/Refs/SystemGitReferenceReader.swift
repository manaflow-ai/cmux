import Foundation

/// Reads file-backed refs directly and delegates other storage backends to Git.
struct SystemGitReferenceReader: GitReferenceReading {
    private static let maximumSymbolicReferenceByteCount = 16 * 1_024
    private static let maximumObjectIDByteCount = 128

    /// The bounded process runner used only for non-files reference storage.
    private let runner: any WorkspaceChangesGitRunning

    /// Creates a production reader backed by the system Git executable.
    init(
        boundedCommandWallTimeLimit: TimeInterval = GitMetadataSafetyConfiguration().gitStatusWallTime
    ) {
        runner = SystemWorkspaceChangesGitRunner(
            boundedCommandWallTimeLimit: boundedCommandWallTimeLimit
        )
    }

    /// Creates a reader with an injected runner for deterministic tests.
    init(runner: any WorkspaceChangesGitRunning) {
        self.runner = runner
    }

    /// Resolves refs using direct files or Git plumbing according to storage.
    func snapshot(repository: ResolvedGitRepository) -> GitReferenceSnapshot {
        if requiresGitPlumbing(repository: repository) {
            return plumbingSnapshot(repository: repository)
        }
        return fileSnapshot(repository: repository)
    }

    /// Builds a snapshot from loose/packed reference files.
    private func fileSnapshot(repository: ResolvedGitRepository) -> GitReferenceSnapshot {
        let headSignature = GitMetadataService.gitHeadSignature(repository: repository)
        return GitReferenceSnapshot(
            checkedOutBranch: GitMetadataService.gitCheckedOutBranch(repository: repository),
            headSignature: headSignature,
            currentCommit: Self.currentCommit(fromHeadSignature: headSignature)
        )
    }

    /// Builds a snapshot from Git's storage-independent plumbing commands.
    private func plumbingSnapshot(repository: ResolvedGitRepository) -> GitReferenceSnapshot {
        let symbolicReference = output(
            arguments: ["symbolic-ref", "--quiet", "HEAD"],
            repository: repository,
            maximumByteCount: Self.maximumSymbolicReferenceByteCount
        )
        let currentCommit = output(
            arguments: ["rev-parse", "--verify", "HEAD^{commit}"],
            repository: repository,
            maximumByteCount: Self.maximumObjectIDByteCount
        ).flatMap(Self.normalizedObjectID)

        let branchPrefix = "refs/heads/"
        let checkedOutBranch: GitCheckedOutBranch
        if let symbolicReference, symbolicReference.hasPrefix(branchPrefix),
           let branch = GitMetadataService.normalizedBranchName(
               String(symbolicReference.dropFirst(branchPrefix.count))
           ) {
            checkedOutBranch = .branch(branch)
        } else if symbolicReference != nil || currentCommit != nil {
            checkedOutBranch = .detached
        } else {
            checkedOutBranch = .unreadable
        }

        let headSignature: String?
        if let symbolicReference {
            headSignature = "ref: \(symbolicReference)\n\(currentCommit ?? "")"
        } else {
            headSignature = currentCommit
        }
        return GitReferenceSnapshot(
            checkedOutBranch: checkedOutBranch,
            headSignature: headSignature,
            currentCommit: currentCommit
        )
    }

    /// Runs one bounded plumbing command and returns trimmed UTF-8 output.
    private func output(
        arguments: [String],
        repository: ResolvedGitRepository,
        maximumByteCount: Int
    ) -> String? {
        guard let result = try? runner.run(
            arguments: arguments,
            in: URL(fileURLWithPath: repository.workTreeRoot, isDirectory: true),
            maximumOutputByteCount: maximumByteCount
        ),
        result.exitCode == 0,
        !result.standardOutputWasTruncated,
        let output = String(data: result.output, encoding: .utf8) else {
            return nil
        }
        return GitMetadataService.normalizedBranchName(output)
    }

    /// Whether repository metadata declares or contains a non-files ref store.
    private func requiresGitPlumbing(repository: ResolvedGitRepository) -> Bool {
        if referenceStorageName(repository: repository).map({ $0 != "files" }) == true {
            return true
        }
        return [repository.gitDirectory, repository.commonDirectory].contains { directory in
            var isDirectory: ObjCBool = false
            let path = URL(fileURLWithPath: directory)
                .appendingPathComponent("reftable", isDirectory: true).path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    /// Reads the local extensions.refStorage value, if one is declared.
    private func referenceStorageName(repository: ResolvedGitRepository) -> String? {
        var storageName: String?
        var seenPaths: Set<String> = []
        for configURL in GitMetadataService.gitRootConfigURLs(repository: repository) {
            let configURL = configURL.standardizedFileURL
            guard seenPaths.insert(configURL.path).inserted,
                  let config = try? String(contentsOf: configURL, encoding: .utf8) else {
                continue
            }
            var isExtensionsSection = false
            for rawLine in config.components(separatedBy: .newlines) {
                let line = GitMetadataService.gitConfigLineRemovingInlineComment(rawLine)
                    .trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") && line.hasSuffix("]") {
                    isExtensionsSection = line.lowercased() == "[extensions]"
                    continue
                }
                guard isExtensionsSection else { continue }
                let parts = line.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard parts.count == 2, parts[0].lowercased() == "refstorage" else {
                    continue
                }
                let value = GitMetadataService.gitConfigUnquotedValue(parts[1]).lowercased()
                if !value.isEmpty {
                    storageName = value
                }
            }
        }
        return storageName
    }

    /// Accepts only complete SHA-1 or SHA-256 object IDs.
    private static func normalizedObjectID(_ value: String) -> String? {
        let normalized = value.lowercased()
        guard normalized.count == 40 || normalized.count == 64,
              normalized.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return normalized
    }

    /// Extracts the resolved object ID from a file-backed head signature.
    private static func currentCommit(fromHeadSignature signature: String?) -> String? {
        guard let signature else { return nil }
        let value = signature.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).last.map(String.init) ?? signature
        return normalizedObjectID(value)
    }
}
