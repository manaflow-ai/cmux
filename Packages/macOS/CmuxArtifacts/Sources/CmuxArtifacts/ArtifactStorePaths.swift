public import Foundation

/// Deterministic paths inside one project's `.cmux` directory.
public struct ArtifactStorePaths: Equatable, Sendable {
    /// Normalized project root.
    public let projectRoot: URL

    /// Creates store paths for a project root.
    ///
    /// - Parameter projectRoot: Directory that owns `.cmux`.
    public init(projectRoot: URL) {
        self.projectRoot = projectRoot.standardizedFileURL
    }

    /// Project-local cmux directory.
    public var cmuxDirectory: URL {
        projectRoot.appendingPathComponent(".cmux", isDirectory: true)
    }

    /// Ordinary artifact filesystem root.
    public var artifactsRoot: URL {
        cmuxDirectory.appendingPathComponent("artifacts", isDirectory: true)
    }

    /// Optional project capture configuration.
    public var configurationFile: URL {
        cmuxDirectory.appendingPathComponent("artifacts.json", isDirectory: false)
    }

    /// Hidden cmux-managed metadata root excluded from the sidebar tree.
    public var metadataRoot: URL {
        artifactsRoot.appendingPathComponent(".cmux", isDirectory: true)
    }

    /// Content-addressed provenance directory.
    public var provenanceRoot: URL {
        metadataRoot.appendingPathComponent("provenance", isDirectory: true)
    }
}
