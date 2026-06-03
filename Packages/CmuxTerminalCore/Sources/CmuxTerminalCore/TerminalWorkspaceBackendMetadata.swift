/// Backend-provided metadata for a terminal workspace, streamed from the cmux backend.
public struct TerminalWorkspaceBackendMetadata: Codable, Equatable, Sendable {
    /// The latest preview text for the workspace, if any.
    public var preview: String?

    /// Creates backend metadata.
    /// - Parameter preview: The latest preview text, if any.
    public init(preview: String? = nil) {
        self.preview = preview
    }
}
