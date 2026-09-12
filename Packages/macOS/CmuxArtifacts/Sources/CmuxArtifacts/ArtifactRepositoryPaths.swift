import Foundation

/// Canonical on-disk locations for one local artifact catalog.
public struct ArtifactRepositoryPaths: Equatable, Sendable {
    /// Root directory containing the catalog and managed payloads.
    public let root: URL
    /// Versioned JSON catalog file.
    public let catalog: URL
    /// Directory containing copied file payloads.
    public let payloads: URL

    /// Creates paths below an injected application-support directory.
    public init(root: URL) {
        let normalized = root.standardizedFileURL
        self.root = normalized
        self.catalog = normalized.appendingPathComponent("catalog-v1.json", isDirectory: false)
        self.payloads = normalized.appendingPathComponent("payloads", isDirectory: true)
    }

    /// Returns whether a URL is contained by the repository root.
    public func contains(_ url: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}
