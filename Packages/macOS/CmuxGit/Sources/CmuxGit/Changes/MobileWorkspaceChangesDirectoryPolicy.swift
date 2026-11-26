/// Resolves whether a workspace directory is safe to pass to local Git.
public struct MobileWorkspaceChangesDirectoryPolicy: Sendable {
    /// Creates a provenance guard.
    public init() {}

    /// Resolves a presented directory without exposing remote paths as local candidates.
    ///
    /// - Parameters:
    ///   - presentedDirectory: Effective directory reported by the workspace.
    ///   - usesRemoteDirectoryProvenance: Whether the directory belongs to a remote host.
    /// - Returns: A provenance-aware resolution for the RPC boundary.
    public func resolve(
        presentedDirectory: String?,
        usesRemoteDirectoryProvenance: Bool
    ) -> MobileWorkspaceChangesDirectoryResolution {
        guard !usesRemoteDirectoryProvenance else { return .remote }
        guard let presentedDirectory else { return .unavailable }
        return .local(presentedDirectory)
    }
}
