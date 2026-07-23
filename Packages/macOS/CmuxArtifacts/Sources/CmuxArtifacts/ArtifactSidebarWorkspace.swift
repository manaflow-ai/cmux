public import Foundation

/// Immutable selected-workspace input used to bind the Artifacts sidebar.
public struct ArtifactSidebarWorkspace: Equatable, Sendable {
    /// Stable cmux workspace identity.
    public let id: String
    /// Human-readable workspace title used for capture grouping.
    public let title: String?
    /// Current local working directory from which the project root is resolved.
    public let workingDirectory: URL

    /// Creates a sidebar workspace snapshot.
    ///
    /// - Parameters:
    ///   - id: Stable cmux workspace identity.
    ///   - title: Human-readable workspace title.
    ///   - workingDirectory: Current local working directory.
    public init(id: String, title: String? = nil, workingDirectory: URL) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory.standardizedFileURL
    }
}
