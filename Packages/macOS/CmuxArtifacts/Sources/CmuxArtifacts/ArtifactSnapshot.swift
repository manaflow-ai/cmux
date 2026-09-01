public import Foundation

/// One authoritative filesystem scan of a project's artifact store.
public struct ArtifactSnapshot: Equatable, Sendable {
    /// Project root used for the scan.
    public let projectRoot: URL
    /// Absolute project `.cmux` directory.
    public let filesystemRoot: URL
    /// Top-level tree nodes.
    public let nodes: [ArtifactNode]
    /// Whether the scan stopped at its defensive node budget.
    public let isTruncated: Bool

    /// Creates a filesystem snapshot.
    ///
    /// - Parameters:
    ///   - projectRoot: Project root used for the scan.
    ///   - filesystemRoot: Absolute project `.cmux` filesystem root.
    ///   - nodes: Top-level immutable tree nodes.
    ///   - isTruncated: Whether a defensive scan limit stopped traversal.
    public init(projectRoot: URL, filesystemRoot: URL, nodes: [ArtifactNode], isTruncated: Bool) {
        self.projectRoot = projectRoot
        self.filesystemRoot = filesystemRoot
        self.nodes = nodes
        self.isTruncated = isTruncated
    }
}
