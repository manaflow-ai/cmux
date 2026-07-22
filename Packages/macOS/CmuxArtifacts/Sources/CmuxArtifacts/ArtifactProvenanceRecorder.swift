import Foundation

/// Persists content-addressed capture history independently of artifact paths.
struct ArtifactProvenanceRecorder {
    let fileManager: FileManager
    let encoder: JSONEncoder
    let decoder: JSONDecoder

    func document(paths: ArtifactStorePaths, digest: String) throws -> ArtifactMetadataDocument? {
        let url = metadataURL(paths: paths, digest: digest)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(ArtifactMetadataDocument.self, from: data)
    }

    func record(
        paths: ArtifactStorePaths,
        digest: String,
        relativePath: String,
        size: Int64,
        event: ArtifactProvenanceEvent
    ) throws {
        try rejectSymbolicLink(at: paths.cmuxDirectory)
        try rejectSymbolicLink(at: paths.artifactsRoot)
        try rejectSymbolicLink(at: paths.metadataRoot)
        try rejectSymbolicLink(at: paths.provenanceRoot)
        try fileManager.createDirectory(at: paths.provenanceRoot, withIntermediateDirectories: true)
        try rejectSymbolicLink(at: paths.cmuxDirectory)
        try rejectSymbolicLink(at: paths.artifactsRoot)
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
        document.lastKnownRelativePath = relativePath
        document.events.append(event)
        if document.events.count > 100 {
            document.events.removeFirst(document.events.count - 100)
        }
        let data = try encoder.encode(document)
        try data.write(to: metadataURL(paths: paths, digest: digest), options: .atomic)
    }

    private func metadataURL(paths: ArtifactStorePaths, digest: String) -> URL {
        paths.provenanceRoot.appendingPathComponent("\(digest).json", isDirectory: false)
    }

    private func rejectSymbolicLink(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw ArtifactStoreError.pathOutsideStore(url.path)
        }
    }
}
