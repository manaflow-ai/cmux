public import Foundation

/// One authoritative filesystem scan of a project's artifact store.
public struct ArtifactSnapshot: Equatable, Sendable {
    /// Project root used for the scan.
    public let projectRoot: URL
    /// Absolute `.cmux/artifacts` directory.
    public let artifactsRoot: URL
    /// Top-level tree nodes.
    public let nodes: [ArtifactNode]
    /// Whether the scan stopped at its defensive node budget.
    public let isTruncated: Bool

    /// Creates a filesystem snapshot.
    ///
    /// - Parameters:
    ///   - projectRoot: Project root used for the scan.
    ///   - artifactsRoot: Absolute artifact filesystem root.
    ///   - nodes: Top-level immutable tree nodes.
    ///   - isTruncated: Whether a defensive scan limit stopped traversal.
    public init(projectRoot: URL, artifactsRoot: URL, nodes: [ArtifactNode], isTruncated: Bool) {
        self.projectRoot = projectRoot
        self.artifactsRoot = artifactsRoot
        self.nodes = nodes
        self.isTruncated = isTruncated
    }
}
