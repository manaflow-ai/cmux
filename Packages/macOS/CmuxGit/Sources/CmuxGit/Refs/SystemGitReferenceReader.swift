import Foundation

/// Reads file-backed refs directly and delegates other storage backends to Git.
nonisolated struct SystemGitReferenceReader: GitReferenceReading {
    private static let maximumSymbolicReferenceByteCount = 16 * 1_024
    private static let maximumObjectIDByteCount = 128
    /// Configs above this bound use Git plumbing instead of an unbounded scan.
    private static let maximumReferenceStorageConfigByteCount = 1 * 1_024 * 1_024

    /// The bounded process runner used only for non-files reference storage.
    private let runner: any WorkspaceChangesGitRunning
    private let storageProbe: any GitReferenceStorageProbing
    private let configReader: GitConfigFileReader

    /// Creates a production reader backed by the system Git executable.
    init(
        boundedCommandWallTimeLimit: TimeInterval = GitMetadataSafetyConfiguration().gitStatusWallTime,
        storageProbe: (any GitReferenceStorageProbing)? = nil,
        configReader: GitConfigFileReader = GitConfigFileReader(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let executableResolver = SystemGitExecutableResolver(environment: environment)
        runner = SystemWorkspaceChangesGitRunner(
            executableURLs: executableResolver.referenceExecutableURLs(),
            environment: environment,
            boundedCommandWallTimeLimit: boundedCommandWallTimeLimit,
            allowsExecutableFallback: true
        )
        self.storageProbe = storageProbe ?? SystemGitReferenceStorageProbe()
        self.configReader = configReader
    }

    /// Creates a reader with an injected runner for deterministic tests.
    init(
        runner: any WorkspaceChangesGitRunning,
        storageProbe: (any GitReferenceStorageProbing)? = nil,
        configReader: GitConfigFileReader = GitConfigFileReader()
    ) {
        self.runner = runner
        self.storageProbe = storageProbe ?? SystemGitReferenceStorageProbe()
        self.configReader = configReader
    }

    /// Resolves refs using direct files or Git plumbing according to storage.
    func snapshot(repository: ResolvedGitRepository) -> GitReferenceSnapshot {
        if requiresGitPlumbing(repository: repository) {
            return plumbingSnapshot(repository: repository)
        }
        return fileSnapshot(repository: repository)
    }

    /// Reports whether this repository needs storage-independent Git plumbing.
    func requiresGitPlumbing(repository: ResolvedGitRepository) -> Bool {
        let hasReftableDirectory = [repository.gitDirectory, repository.commonDirectory].contains { directory in
            let path = URL(fileURLWithPath: directory)
                .appendingPathComponent("reftable", isDirectory: true).path
            return storageProbe.isDirectory(atPath: path)
        }
        if hasReftableDirectory {
            return true
        }
        // A valid file-backed HEAD already resolves its object ID without a
        // config scan. Only ambiguous/unborn/malformed heads need backend
        // detection, keeping ordinary sidebar refreshes on the direct path.
        if fileBackedHeadHasResolvedCommit(repository: repository) {
            return false
        }
        return referenceStorageName(repository: repository).map({ $0 != "files" }) == true
    }

    /// Builds a snapshot from loose/packed reference files.
    private func fileSnapshot(repository: ResolvedGitRepository) -> GitReferenceSnapshot {
        let headSignature = GitMetadataService.gitHeadSignature(repository: repository)
        return GitReferenceSnapshot(
            checkedOutBranch: GitMetadataService.gitCheckedOutBranch(repository: repository),
            headSignature: headSignature,
            currentCommit: currentCommit(fromHeadSignature: headSignature)
        )
    }

    /// Builds a snapshot from Git's storage-independent plumbing commands.
    private func plumbingSnapshot(repository: ResolvedGitRepository) -> GitReferenceSnapshot {
        let symbolicReference = output(
            arguments: ["symbolic-ref", "--quiet", "HEAD"],
            repository: repository,
            maximumByteCount: Self.maximumSymbolicReferenceByteCount
        )

        if let symbolicReference, symbolicReference.hasPrefix("refs/heads/") {
            guard let stableReference = stableBranchReference(
                initialSymbolicReference: symbolicReference,
                repository: repository
            ),
            let branch = GitMetadataService.normalizedBranchName(
                String(stableReference.symbolicReference.dropFirst("refs/heads/".count))
            ) else {
                return GitReferenceSnapshot(
                    checkedOutBranch: .unreadable,
                    headSignature: nil,
                    currentCommit: nil
                )
            }
            return GitReferenceSnapshot(
                checkedOutBranch: .branch(branch),
                headSignature: "ref: \(stableReference.symbolicReference)\n\(stableReference.currentCommit ?? "")",
                currentCommit: stableReference.currentCommit
            )
        }

        let currentCommit = output(
            arguments: ["rev-parse", "--verify", "HEAD^{commit}"],
            repository: repository,
            maximumByteCount: Self.maximumObjectIDByteCount
        ).flatMap { normalizedObjectID($0) }

        let checkedOutBranch: GitCheckedOutBranch
        if symbolicReference != nil || currentCommit != nil {
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

    /// Resolves a branch ref and verifies that HEAD still names it afterward.
    private func stableBranchReference(
        initialSymbolicReference: String,
        repository: ResolvedGitRepository
    ) -> (symbolicReference: String, currentCommit: String?)? {
        var symbolicReference = initialSymbolicReference
        for _ in 0..<2 {
            let currentCommit = resolvedCommit(
                for: symbolicReference,
                repository: repository
            )
            guard currentCommit != nil || isLegitimateUnbornReference(symbolicReference) else {
                return nil
            }
            guard let verifiedSymbolicReference = output(
                arguments: ["symbolic-ref", "--quiet", "HEAD"],
                repository: repository,
                maximumByteCount: Self.maximumSymbolicReferenceByteCount
            ) else {
                return nil
            }
            let verifiedCommit = resolvedCommit(
                for: verifiedSymbolicReference,
                repository: repository
            )
            if verifiedSymbolicReference == symbolicReference {
                if let currentCommit, currentCommit == verifiedCommit {
                    return (symbolicReference, currentCommit)
                }
                if currentCommit == nil,
                   verifiedCommit == nil,
                   isLegitimateUnbornReference(symbolicReference) {
                    // Git's reftable worktree compatibility HEAD uses the
                    // `.invalid` sentinel; never publish that value. A named
                    // branch with no object is the legitimate unborn case.
                    return (symbolicReference, nil)
                }
            }
            symbolicReference = verifiedSymbolicReference
            guard symbolicReference.hasPrefix("refs/heads/") else { return nil }
        }
        return nil
    }

    /// Returns true for a named branch that may legitimately have no commit.
    private func isLegitimateUnbornReference(_ symbolicReference: String) -> Bool {
        guard symbolicReference.hasPrefix("refs/heads/") else { return false }
        return String(symbolicReference.dropFirst("refs/heads/".count)) != ".invalid"
    }

    /// Resolves one branch ref to a complete object ID, or nil when plumbing
    /// cannot prove a commit (including an unborn or unsupported ref backend).
    private func resolvedCommit(
        for symbolicReference: String,
        repository: ResolvedGitRepository
    ) -> String? {
        output(
            arguments: [
                "rev-parse",
                "--verify",
                "\(symbolicReference)^{commit}",
            ],
            repository: repository,
            maximumByteCount: Self.maximumObjectIDByteCount
        ).flatMap { normalizedObjectID($0) }
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

    /// Reads the local extensions.refStorage value, if one is declared.
    ///
    /// Root config files are size-bounded before decoding. An oversized config
    /// returns an unknown storage name, which conservatively selects Git
    /// plumbing rather than allowing repeated refreshes to scan unbounded data.
    private func referenceStorageName(repository: ResolvedGitRepository) -> String? {
        var storageName: String?
        var seenPaths: Set<String> = []
        for configURL in GitMetadataService.gitRootConfigURLs(repository: repository) {
            let configURL = configURL.standardizedFileURL
            guard seenPaths.insert(configURL.path).inserted else {
                continue
            }
            let configRead = boundedReferenceStorageConfig(at: configURL)
            if configRead.isOversized {
                return "unknown"
            }
            guard let config = configRead.contents else {
                continue
            }
            var isExtensionsSection = false
            config.enumerateLines { rawLine, _ in
                let line = GitMetadataService.gitConfigLineRemovingInlineComment(rawLine)
                    .trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") && line.hasSuffix("]") {
                    isExtensionsSection = line.lowercased() == "[extensions]"
                    return
                }
                guard isExtensionsSection else { return }
                let parts = line.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard parts.count == 2, parts[0].lowercased() == "refstorage" else {
                    return
                }
                let value = GitMetadataService.gitConfigUnquotedValue(parts[1]).lowercased()
                if !value.isEmpty {
                    storageName = value
                }
            }
        }
        return storageName
    }

    /// Whether a file-backed HEAD already resolves to a complete object ID.
    private func fileBackedHeadHasResolvedCommit(repository: ResolvedGitRepository) -> Bool {
        let headURL = URL(fileURLWithPath: repository.gitDirectory)
            .appendingPathComponent("HEAD")
        guard let contents = try? String(contentsOf: headURL, encoding: .utf8) else {
            return false
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ref: ") else {
            return normalizedObjectID(trimmed) != nil
        }
        let refName = String(trimmed.dropFirst("ref: ".count))
        guard !refName.isEmpty,
              let value = GitMetadataService.gitRefValue(
                  repository: repository,
                  refName: refName
              ) else {
            return false
        }
        return normalizedObjectID(value) != nil
    }

    /// Reads at most the configured backend-detection limit from one config.
    nonisolated func boundedReferenceStorageConfig(
        at configURL: URL
    ) -> (contents: String?, isOversized: Bool) {
        switch configReader.read(
            at: configURL,
            maximumByteCount: Self.maximumReferenceStorageConfigByteCount
        ) {
        case .contents(let contents):
            return (contents, false)
        case .oversized:
            return (nil, true)
        case .unavailable:
            return (nil, false)
        }
    }

    /// Accepts only complete SHA-1 or SHA-256 object IDs.
    private func normalizedObjectID(_ value: String) -> String? {
        let normalized = value.lowercased()
        guard normalized.count == 40 || normalized.count == 64,
              normalized.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return normalized
    }

    /// Extracts the resolved object ID from a file-backed head signature.
    private func currentCommit(fromHeadSignature signature: String?) -> String? {
        guard let signature else { return nil }
        let value = signature.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).last.map(String.init) ?? signature
        return normalizedObjectID(value)
    }
}
