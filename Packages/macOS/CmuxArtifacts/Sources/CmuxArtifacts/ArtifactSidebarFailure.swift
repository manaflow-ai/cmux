/// Recoverable user action that failed in the Artifacts sidebar.
public enum ArtifactSidebarFailure: String, Identifiable, Equatable, Sendable {
    /// A manual file import failed validation or persistence.
    case add
    /// A filename or content search could not complete.
    case search

    /// Stable identity used by alert presentation.
    public var id: String { rawValue }
}
