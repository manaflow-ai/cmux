import CmuxFoundation
public import Foundation

/// Actor-backed local repository for one or more project artifact stores.
///
/// Ordinary files under `.cmux/artifacts` are authoritative. Hidden metadata is
/// content-addressed so user-driven file moves and renames do not invalidate
/// deduplication or provenance.
public actor LocalArtifactRepository: ArtifactStoring {
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let maximumScanDepth: Int
    private let nodeBudget: Int

    /// Creates a local filesystem repository.
    ///
    /// - Parameters:
    ///   - fileManager: Filesystem dependency used by storage and tests.
    ///   - maximumScanDepth: Defensive recursive tree depth.
    ///   - nodeBudget: Defensive number of files and folders scanned at once.
    public init(
        fileManager: FileManager = .default,
        maximumScanDepth: Int = 32,
        nodeBudget: Int = 20_000
    ) {
        self.fileManager = fileManager
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

    /// Loads a partial `.cmux/artifacts.json`, falling back safely on errors.
    public func configuration(projectRoot: URL) -> ArtifactCaptureConfiguration {
        let url = ArtifactStorePaths(projectRoot: projectRoot).configurationFile
        guard let data = try? Data(contentsOf: url),
              let configuration = try? decoder.decode(ArtifactCaptureConfiguration.self, from: data) else {
            return .defaultValue
        }
        return configuration.normalized
    }

    /// Scans the live ordinary-file tree, creating the store on first use.
    public func snapshot(projectRoot: URL) throws -> ArtifactSnapshot {
        let paths = ArtifactStorePaths(projectRoot: projectRoot)
        try prepare(paths: paths)
        return try scanner.snapshot(paths: paths)
    }

    /// Searches fuzzy filenames and bounded UTF-8 contents from a live scan.
    public func search(projectRoot: URL, query: String) throws -> [ArtifactSearchResult] {
        let snapshot = try snapshot(projectRoot: projectRoot)
        let configuration = configuration(projectRoot: projectRoot)
        return ArtifactSearchEngine(configuration: configuration).results(snapshot: snapshot, query: query)
    }

    /// Imports, deduplicates, or records a file already inside the store.
    public func importFile(
        sourceURL: URL,
        context: ArtifactCaptureContext,
        provenance: ArtifactProvenance,
        configuration: ArtifactCaptureConfiguration,
        capturedAt: Date
    ) throws -> ArtifactImportOutcome {
        let paths = ArtifactStorePaths(projectRoot: context.projectRoot)
        try prepare(paths: paths)
        let source = sourceURL.standardizedFileURL
        let size = try validatedSize(source: source, configuration: configuration.normalized)
        let digest = try ArtifactDigestCalculator().digest(url: source)
        let pathResolver = ArtifactPathResolver()

        if pathResolver.isInsideStore(source, paths: paths),
           let relativePath = pathResolver.relativePath(source, root: paths.artifactsRoot) {
            let record = makeRecord(
                digest: digest,
                source: source,
                relativePath: relativePath,
                context: context,
                provenance: provenance,
                capturedAt: capturedAt,
                size: size
            )
            try recordProvenance(record, paths: paths)
            return .alreadyStored(record)
        }

        if let existing = try existingFile(digest: digest, size: size, paths: paths),
           let relativePath = pathResolver.relativePath(existing, root: paths.artifactsRoot) {
            let record = makeRecord(
                digest: digest,
                source: source,
                relativePath: relativePath,
                context: context,
                provenance: provenance,
                capturedAt: capturedAt,
                size: size
            )
            try recordProvenance(record, paths: paths)
            return .deduplicated(record)
        }

        let captureDirectoryResolution = ArtifactCaptureDirectoryFinder(
            fileManager: fileManager,
            decoder: decoder,
            nodeBudget: nodeBudget
        ).resolve(paths: paths, context: context, pathResolver: pathResolver)
        let captureDirectory = captureDirectoryResolution.directory
        try createCaptureDirectory(
            captureDirectory,
            paths: paths,
            context: context,
            capturedAt: capturedAt,
            writesWorkspaceMarker: !captureDirectoryResolution.reusedSessionMarker
        )
        let destination = pathResolver.uniqueDestination(
            source: source,
            directory: captureDirectory,
            fileManager: fileManager
        )
        try copyAtomically(source: source, destination: destination)
        guard let relativePath = pathResolver.relativePath(destination, root: paths.artifactsRoot) else {
            throw ArtifactStoreError.pathOutsideStore(destination.path)
        }
        let record = makeRecord(
            digest: digest,
            source: source,
            relativePath: relativePath,
            context: context,
            provenance: provenance,
            capturedAt: capturedAt,
            size: size
        )
        try recordProvenance(record, paths: paths)
        return .copied(record)
    }

    /// Resolves an exact relative path, unique basename, or unique fuzzy match.
    public func resolve(projectRoot: URL, name rawName: String) throws -> ArtifactNode {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = try snapshot(projectRoot: projectRoot)
        let files = flatten(snapshot.nodes).filter { !$0.isDirectory }
        if let exact = files.first(where: { $0.relativePath == name }) {
            return exact
        }
        let basenameMatches = files.filter { $0.name == name }
        if basenameMatches.count == 1, let match = basenameMatches.first { return match }
        if basenameMatches.count > 1 {
            throw ArtifactStoreError.ambiguousArtifactName(name, matches: basenameMatches.map(\.relativePath))
        }
        let matcher = ArtifactFuzzyMatcher()
        let fuzzyMatches = files.compactMap { node in
            matcher.score(candidate: node.relativePath, query: name).map { (node, $0) }
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
        guard let watcher = RecursivePathWatcher(paths: [paths.artifactsRoot.path]) else {
            return AsyncStream { $0.finish() }
        }
        return AsyncStream { continuation in
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

    private func prepare(paths: ArtifactStorePaths) throws {
        try rejectSymbolicLink(at: paths.cmuxDirectory)
        try rejectSymbolicLink(at: paths.artifactsRoot)
        try fileManager.createDirectory(at: paths.artifactsRoot, withIntermediateDirectories: true)
        try rejectSymbolicLink(at: paths.cmuxDirectory)
        try rejectSymbolicLink(at: paths.artifactsRoot)
        try rejectSymbolicLinks(
            from: paths.artifactsRoot,
            through: paths.provenanceRoot
        )
        try ArtifactGitIgnoreManager(fileManager: fileManager).ensureIgnored(projectRoot: paths.projectRoot)
    }

    private func validatedSize(
        source: URL,
        configuration: ArtifactCaptureConfiguration
    ) throws -> Int64 {
        let values = try? source.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
            throw ArtifactStoreError.sourceNotRegularFile(source.path)
        }
        let pathExtension = source.pathExtension.lowercased()
        guard configuration.allowedExtensions.contains(pathExtension) else {
            throw ArtifactStoreError.unsupportedExtension(pathExtension)
        }
        let size = Int64(values?.fileSize ?? 0)
        let limit = ArtifactFileKind.classify(source) == .text
            ? configuration.maximumTextFileBytes
            : configuration.maximumFileBytes
        guard size <= limit else {
            throw ArtifactStoreError.fileTooLarge(actual: size, limit: limit)
        }
        return size
    }

    private func existingFile(digest: String, size: Int64, paths: ArtifactStorePaths) throws -> URL? {
        for file in try scanner.allFiles(paths: paths) {
            guard let existingSize = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(existingSize) == size,
                  let existingDigest = try? ArtifactDigestCalculator().digest(url: file) else {
                continue
            }
            if existingDigest == digest { return file }
        }
        return nil
    }

    private func createCaptureDirectory(
        _ sessionDirectory: URL,
        paths: ArtifactStorePaths,
        context: ArtifactCaptureContext,
        capturedAt: Date,
        writesWorkspaceMarker: Bool
    ) throws {
        try rejectSymbolicLinks(from: paths.artifactsRoot, through: sessionDirectory)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try rejectSymbolicLinks(from: paths.artifactsRoot, through: sessionDirectory)
        let workspaceDirectory = sessionDirectory.deletingLastPathComponent()
        if writesWorkspaceMarker {
            try writeMarkerIfMissing(
                ArtifactWorkspaceMarker(
                    workspaceID: context.workspaceID,
                    workspaceTitle: context.workspaceTitle,
                    createdAt: capturedAt
                ),
                to: workspaceDirectory.appendingPathComponent(ArtifactPathResolver.workspaceMarkerName)
            )
        }
        try writeMarkerIfMissing(
            ArtifactSessionMarker(
                sessionID: context.sessionID,
                agentName: context.agentName,
                createdAt: capturedAt
            ),
            to: sessionDirectory.appendingPathComponent(ArtifactPathResolver.sessionMarkerName)
        )
    }

    private func writeMarkerIfMissing(_ value: some Encodable, to url: URL) throws {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func rejectSymbolicLinks(from root: URL, through descendant: URL) throws {
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

    private func rejectSymbolicLink(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw ArtifactStoreError.pathOutsideStore(url.path)
        }
    }

    private func copyAtomically(source: URL, destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).artifact-import", isDirectory: false)
        do {
            try fileManager.copyItem(at: source, to: temporary)
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func makeRecord(
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

    private func recordProvenance(_ record: ArtifactRecord, paths: ArtifactStorePaths) throws {
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

    private func flatten(_ nodes: [ArtifactNode]) -> [ArtifactNode] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }
}
