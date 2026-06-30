public import Foundation

/// Filesystem-backed storage for collaboration documents.
public struct LocalCollaborationFileStore: CollaborationFileStoring {
    /// Creates a local file store backed by `FileManager.default`.
    public init() {}

    public func readText(at url: URL) async throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    public func writeText(_ text: String, to url: URL) async throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public func fileExists(at url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
