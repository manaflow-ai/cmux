import Foundation

/// Persists content-addressed capture history independently of artifact paths.
struct ArtifactProvenanceRecorder {
    static let maximumDocumentBytes: Int64 = 256 * 1024
    private static let maximumEventFieldCharacters = 4_096

    let fileManager: FileManager
    let encoder: JSONEncoder
    let decoder: JSONDecoder

    func document(paths: ArtifactStorePaths, digest: String) throws -> ArtifactMetadataDocument? {
        let url = metadataURL(paths: paths, digest: digest)
        let reader = ArtifactBoundedFileReader()
        do {
            guard try reader.pathEntryExists(url: url) else { return nil }
            guard let data = try reader.data(
                url: url,
                allowedRoot: paths.provenanceRoot,
                maximumBytes: Self.maximumDocumentBytes
            ) else {
                throw ArtifactStoreError.corruptProvenance(url.path)
            }
            return try decoder.decode(ArtifactMetadataDocument.self, from: data)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw ArtifactStoreError.corruptProvenance(url.path)
        }
    }

    func record(
        paths: ArtifactStorePaths,
        digest: String,
        relativePath: String,
        size: Int64,
        event: ArtifactProvenanceEvent
    ) throws {
        try rejectSymbolicLink(at: paths.filesystemRoot)
        try rejectSymbolicLink(at: paths.metadataRoot)
        try rejectSymbolicLink(at: paths.provenanceRoot)
        try fileManager.createDirectory(at: paths.provenanceRoot, withIntermediateDirectories: true)
        try rejectSymbolicLink(at: paths.filesystemRoot)
        try rejectSymbolicLink(at: paths.metadataRoot)
        try rejectSymbolicLink(at: paths.provenanceRoot)
        try rejectSymbolicLink(at: metadataURL(paths: paths, digest: digest))
        var document = try document(paths: paths, digest: digest) ?? ArtifactMetadataDocument(
            version: 1,
            digest: digest,
            lastKnownRelativePath: relativePath,
            size: size,
            events: []
        )
        guard document.digest == digest, document.size == size else {
            throw ArtifactStoreError.corruptProvenance(
                metadataURL(paths: paths, digest: digest).path
            )
        }
        document.lastKnownRelativePath = relativePath
        document.events.append(bounded(event))
        if document.events.count > 100 {
            document.events.removeFirst(document.events.count - 100)
        }
        var data = try encoder.encode(document)
        while Int64(data.count) > Self.maximumDocumentBytes, document.events.count > 1 {
            document.events.removeFirst()
            data = try encoder.encode(document)
        }
        guard Int64(data.count) <= Self.maximumDocumentBytes else {
            throw ArtifactStoreError.corruptProvenance(
                metadataURL(paths: paths, digest: digest).path
            )
        }
        try data.write(to: metadataURL(paths: paths, digest: digest), options: .atomic)
    }

    func metadataURL(paths: ArtifactStorePaths, digest: String) -> URL {
        paths.provenanceRoot.appendingPathComponent("\(digest).json", isDirectory: false)
    }

    private func bounded(_ event: ArtifactProvenanceEvent) -> ArtifactProvenanceEvent {
        ArtifactProvenanceEvent(
            sourcePath: String(event.sourcePath.prefix(Self.maximumEventFieldCharacters)),
            workspaceID: event.workspaceID.map {
                String($0.prefix(Self.maximumEventFieldCharacters))
            },
            sessionID: event.sessionID.map {
                String($0.prefix(Self.maximumEventFieldCharacters))
            },
            provenance: event.provenance,
            capturedAt: event.capturedAt
        )
    }

    private func rejectSymbolicLink(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw ArtifactStoreError.pathOutsideStore(url.path)
        }
    }
}
