import CmuxFoundation
public import Foundation

/// Actor-backed local repository for one or more project artifact stores.
///
/// Ordinary files under session folders in `.cmux` are authoritative. Hidden metadata is
/// content-addressed so user-driven file moves and renames do not invalidate
/// deduplication or provenance.
public actor LocalArtifactRepository: ArtifactStoring {
    private static let maximumConfigurationBytes: Int64 = 64 * 1024
    let fileManager: FileManager
    let decoder: JSONDecoder
    let encoder: JSONEncoder
    let gitCommandRunner: any ArtifactGitCommandRunning
    let now: @Sendable () -> Date
    let maximumScanDepth: Int
    let nodeBudget: Int

    /// Creates a local filesystem repository.
    ///
    /// - Parameters:
    ///   - fileManager: Filesystem dependency used by storage and tests.
    ///   - maximumScanDepth: Defensive recursive tree depth.
    ///   - nodeBudget: Defensive number of files and folders scanned at once.
    ///   - now: Clock seam used to age malformed staging entries.
    public init(
        fileManager: FileManager = .default,
        maximumScanDepth: Int = 32,
        nodeBudget: Int = 20_000,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.fileManager = fileManager
        self.gitCommandRunner = SystemArtifactGitCommandRunner()
        self.now = now
        self.maximumScanDepth = max(1, maximumScanDepth)
        self.nodeBudget = max(1, nodeBudget)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    /// Creates a repository with an injected Git command seam for tests.
    init(
        fileManager: FileManager,
        gitCommandRunner: any ArtifactGitCommandRunning,
        maximumScanDepth: Int = 32,
        nodeBudget: Int = 20_000,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.fileManager = fileManager
        self.gitCommandRunner = gitCommandRunner
        self.now = now
        self.maximumScanDepth = max(1, maximumScanDepth)
        self.nodeBudget = max(1, nodeBudget)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    /// Resolves the nearest `.cmux` or Git project root on the repository actor.
    public func locateProjectRoot(startingAt url: URL) -> URL {
        ArtifactProjectLocator().projectRoot(startingAt: url, fileManager: fileManager)
    }

    /// Loads a partial `.cmux/artifacts.json`, failing closed for automatic capture on errors.
    public func configuration(projectRoot: URL) -> ArtifactCaptureConfiguration {
        let paths = ArtifactStorePaths(projectRoot: projectRoot)
        let url = paths.configurationFile
        let reader = ArtifactBoundedFileReader()
        var failureConfiguration = ArtifactCaptureConfiguration.defaultValue
        failureConfiguration.automaticCaptureEnabled = false
        do {
            guard try reader.pathEntryExists(url: url) else { return .defaultValue }
        } catch {
            return failureConfiguration
        }
        guard let data = try? reader.data(
            url: url,
            allowedRoot: paths.filesystemRoot,
            maximumBytes: Self.maximumConfigurationBytes
        ),
              let configuration = try? decoder.decode(ArtifactCaptureConfiguration.self, from: data) else {
            return failureConfiguration
        }
        return configuration.normalized
    }

    /// Scans the live ordinary-file tree, creating the store on first use.
    public func snapshot(projectRoot: URL) throws -> ArtifactSnapshot {
        let paths = ArtifactStorePaths(projectRoot: projectRoot)
        try prepare(paths: paths)
        return try completeSnapshot(paths: paths)
    }

    /// Searches fuzzy filenames and bounded UTF-8 contents from a live scan.
    public func search(projectRoot: URL, query: String) throws -> [ArtifactSearchResult] {
        try Task.checkCancellation()
        let snapshot = try snapshot(projectRoot: projectRoot)
        try Task.checkCancellation()
        let configuration = configuration(projectRoot: projectRoot)
        return try ArtifactSearchEngine(configuration: configuration).results(
            snapshot: snapshot,
            query: query
        )
    }

    /// Imports, deduplicates, or records a file already inside the store.
    public func importFile(
        sourceURL: URL,
        context: ArtifactCaptureContext,
        provenance: ArtifactProvenance,
        configuration: ArtifactCaptureConfiguration,
        capturedAt: Date
    ) async throws -> ArtifactImportOutcome {
        let attempts = await importFiles(
            candidates: [ArtifactCandidate(sourceURL: sourceURL, provenance: provenance)],
            context: context,
            configuration: configuration,
            capturedAt: capturedAt
        )
        guard let attempt = attempts.first else {
            throw ArtifactStoreError.sourceNotRegularFile(sourceURL.path)
        }
        switch attempt {
        case .imported(let outcome):
            return outcome
        case .rejected(let error):
            throw error
        }
    }

    /// Resolves an exact relative path, unique basename, or unique fuzzy match.
    public func resolve(projectRoot: URL, name rawName: String) throws -> ArtifactNode {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.hasPrefix(".cmux/")
            ? String(trimmedName.dropFirst(".cmux/".count))
            : trimmedName
        let paths = ArtifactStorePaths(projectRoot: projectRoot)
        try prepare(paths: paths)
        if let exact = try ArtifactExactPathResolver().fileNode(
            relativePath: name,
            paths: paths
        ) {
            return exact
        }
        let snapshot = try completeSnapshot(paths: paths)
        let files = snapshot.nodes.flattenedArtifactNodes().filter { !$0.isDirectory }
        let basenameMatches = files.filter { $0.name == name }
        if basenameMatches.count == 1, let match = basenameMatches.first { return match }
        if basenameMatches.count > 1 {
            throw ArtifactStoreError.ambiguousArtifactName(name, matches: basenameMatches.map(\.relativePath))
        }
        let matcher = ArtifactFuzzyMatcher(query: name)
        let fuzzyMatches = files.compactMap { node in
            matcher.score(candidate: node.relativePath).map { (node, $0) }
        }.sorted { $0.1 > $1.1 }
        guard let best = fuzzyMatches.first else {
            throw ArtifactStoreError.artifactNotFound(name)
        }
        if fuzzyMatches.count > 1, fuzzyMatches[1].1 == best.1 {
            throw ArtifactStoreError.ambiguousArtifactName(
                name,
                matches: fuzzyMatches.filter { $0.1 == best.1 }.map { $0.0.relativePath }
            )
        }
        return best.0
    }

    /// Creates a recursive watcher stream that emits immediately and on change.
    public func changes(projectRoot: URL) -> AsyncStream<Void> {
        let paths = ArtifactStorePaths(projectRoot: projectRoot)
        do {
            try prepare(paths: paths)
        } catch {
            return AsyncStream { $0.finish() }
        }
        guard let watcher = RecursivePathWatcher(paths: [paths.filesystemRoot.path]) else {
            return AsyncStream { $0.finish() }
        }
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(())
            let task = Task {
                for await _ in watcher.events {
                    guard !Task.isCancelled else { break }
                    continuation.yield(())
                }
                await watcher.stop()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private var scanner: ArtifactTreeScanner {
        ArtifactTreeScanner(
            fileManager: fileManager,
            maximumDepth: maximumScanDepth,
            nodeBudget: nodeBudget
        )
    }

    func completeSnapshot(paths: ArtifactStorePaths) throws -> ArtifactSnapshot {
        let snapshot = try scanner.snapshot(paths: paths)
        guard !snapshot.isTruncated else {
            throw ArtifactStoreError.scanIncomplete(paths.filesystemRoot.path)
        }
        return snapshot
    }

    func prepare(paths: ArtifactStorePaths) throws {
        try rejectSymbolicLink(at: paths.filesystemRoot)
        try fileManager.createDirectory(at: paths.filesystemRoot, withIntermediateDirectories: true)
        try rejectSymbolicLink(at: paths.filesystemRoot)
        try rejectSymbolicLinks(
            from: paths.filesystemRoot,
            through: paths.provenanceRoot
        )
        try rejectSymbolicLinks(
            from: paths.filesystemRoot,
            through: paths.importStagingRoot
        )
        ArtifactImportStagingCleaner(fileManager: fileManager, now: now)
            .reclaimAbandonedBatches(root: paths.importStagingRoot)
        try ArtifactGitIgnoreManager(fileManager: fileManager).ensureIgnored(projectRoot: paths.projectRoot)
    }

    func createCaptureDirectory(
        _ contentDirectory: URL,
        paths: ArtifactStorePaths,
        context: ArtifactCaptureContext,
        capturedAt: Date
    ) throws {
        try rejectSymbolicLinks(from: paths.filesystemRoot, through: contentDirectory)
        try fileManager.createDirectory(at: contentDirectory, withIntermediateDirectories: true)
        try rejectSymbolicLinks(from: paths.filesystemRoot, through: contentDirectory)
        let sessionDirectory = contentDirectory.deletingLastPathComponent()
        try writeMarkerIfMissing(
            ArtifactWorkspaceMarker(
                workspaceID: context.workspaceID,
                workspaceTitle: context.workspaceTitle,
                createdAt: capturedAt
            ),
            to: sessionDirectory.appendingPathComponent(ArtifactPathResolver.workspaceMarkerName)
        )
        try writeSessionMarkerIfMissing(
            ArtifactSessionMarker(
                sessionID: context.sessionID,
                agentName: context.agentName,
                createdAt: capturedAt
            ),
            to: sessionDirectory.appendingPathComponent(ArtifactPathResolver.sessionMarkerName),
            paths: paths
        )
    }

    private func writeMarkerIfMissing(_ value: some Encodable, to url: URL) throws {
        do {
            try encoder.encode(value).write(to: url, options: .withoutOverwriting)
        } catch {
            guard try ArtifactBoundedFileReader().pathEntryExists(url: url) else { throw error }
        }
    }

    private func writeSessionMarkerIfMissing(
        _ value: ArtifactSessionMarker,
        to url: URL,
        paths: ArtifactStorePaths
    ) throws {
        let reader = ArtifactBoundedFileReader()
        do {
            try encoder.encode(value).write(to: url, options: .withoutOverwriting)
            return
        } catch {
            guard try reader.pathEntryExists(url: url) else { throw error }
        }
        guard let data = try reader.data(
            url: url,
            allowedRoot: paths.filesystemRoot,
            maximumBytes: 256 * 1024
        ), let existing = try? decoder.decode(ArtifactSessionMarker.self, from: data),
              existing.sessionID == value.sessionID else {
            throw ArtifactStoreError.corruptProvenance(url.path)
        }
    }

    func rejectSymbolicLinks(from root: URL, through descendant: URL) throws {
        let pathResolver = ArtifactPathResolver()
        try rejectSymbolicLink(at: root)
        guard !pathResolver.refersToSameLocation(descendant, root) else { return }
        guard let relativePath = pathResolver.relativePath(descendant, root: root) else {
            throw ArtifactStoreError.pathOutsideStore(descendant.path)
        }
        var current = root
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component))
            try rejectSymbolicLink(at: current)
        }
    }

    func rejectSymbolicLink(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw ArtifactStoreError.pathOutsideStore(url.path)
        }
    }

    func makeRecord(
        digest: String,
        source: URL,
        relativePath: String,
        context: ArtifactCaptureContext,
        provenance: ArtifactProvenance,
        capturedAt: Date,
        size: Int64
    ) -> ArtifactRecord {
        ArtifactRecord(
            digest: digest,
            sourcePath: source.path,
            relativePath: relativePath,
            workspaceID: context.workspaceID,
            sessionID: context.sessionID,
            provenance: provenance,
            capturedAt: capturedAt,
            size: size
        )
    }

    func recordProvenance(_ record: ArtifactRecord, paths: ArtifactStorePaths) throws {
        let recorder = ArtifactProvenanceRecorder(
            fileManager: fileManager,
            encoder: encoder,
            decoder: decoder
        )
        try recorder.record(
            paths: paths,
            digest: record.digest,
            relativePath: record.relativePath,
            size: record.size,
            event: ArtifactProvenanceEvent(
                sourcePath: record.sourcePath,
                workspaceID: record.workspaceID,
                sessionID: record.sessionID,
                provenance: record.provenance,
                capturedAt: record.capturedAt
            )
        )
    }
}
