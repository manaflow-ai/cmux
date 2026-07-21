import Foundation

/// Stable project-local location returned after saving a chat artifact.
public struct ChatArtifactSaveResult: Codable, Equatable, Sendable {
    /// Absolute path to the persisted artifact on the Mac.
    public let path: String
    /// Path relative to the project's `.cmux/artifacts` directory.
    public let relativePath: String
    /// Prompt-ready project-relative reference.
    public let reference: String

    /// Creates the location returned for a persisted chat artifact.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the persisted file on the Mac.
    ///   - relativePath: Path relative to the project's artifact root.
    ///   - reference: Prompt-ready project-relative reference.
    public init(path: String, relativePath: String, reference: String) {
        self.path = path
        self.relativePath = relativePath
        self.reference = reference
    }
}
