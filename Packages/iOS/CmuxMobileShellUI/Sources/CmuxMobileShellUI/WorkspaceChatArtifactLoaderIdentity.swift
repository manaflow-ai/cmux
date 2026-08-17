/// Cache identity for artifact loaders owned by one workspace chat pane.
///
/// The event source inside a ``ChatArtifactLoader`` is immutable. Including
/// the shell's source generation here prevents a pane from reusing a loader
/// that still points at a retired RPC client.
struct WorkspaceChatArtifactLoaderIdentity: Equatable, Hashable, Sendable {
    let sessionID: String
    let supportsArtifacts: Bool
    let sourceIdentity: String
}
