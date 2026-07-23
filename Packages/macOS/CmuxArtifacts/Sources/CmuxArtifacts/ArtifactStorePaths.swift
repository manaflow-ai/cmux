public import Foundation

/// Deterministic paths inside one project's session-oriented `.cmux` filesystem.
public struct ArtifactStorePaths: Equatable, Sendable {
    static let trackableControlFileNames = ["artifacts.json", "cmux.json", "dock.json"]

    /// Normalized project root.
    public let projectRoot: URL

    /// Creates store paths for a project root.
    ///
    /// - Parameter projectRoot: Directory that owns `.cmux`.
    public init(projectRoot: URL) {
        self.projectRoot = projectRoot.standardizedFileURL
    }

    /// Ordinary cmux filesystem root.
    ///
    /// Agent sessions are immediate or user-organized descendants whose
    /// `artifacts` and `notes` directories remain ordinary movable folders.
    public var filesystemRoot: URL {
        projectRoot.appendingPathComponent(".cmux", isDirectory: true)
    }

    /// Optional project capture configuration.
    public var configurationFile: URL {
        filesystemRoot.appendingPathComponent("artifacts.json", isDirectory: false)
    }

    /// Hidden cmux-managed metadata root excluded from the sidebar tree.
    public var metadataRoot: URL {
        filesystemRoot.appendingPathComponent(".metadata", isDirectory: true)
    }

    /// Private import staging directory excluded from the sidebar tree.
    var importStagingRoot: URL {
        metadataRoot.appendingPathComponent("imports", isDirectory: true)
    }

    /// Content-addressed provenance directory.
    public var provenanceRoot: URL {
        metadataRoot.appendingPathComponent("provenance", isDirectory: true)
    }
}
