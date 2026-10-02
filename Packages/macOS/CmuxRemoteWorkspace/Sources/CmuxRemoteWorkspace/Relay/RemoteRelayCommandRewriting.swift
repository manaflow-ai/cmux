public import Foundation

/// Inversion seam for the relay's command-line rewriting: the relay maps
/// remote-issued workspace/surface IDs back to local ones before forwarding
/// a CLI command to the local cmux socket, but the alias-aware rewrite logic
/// lives with the workspace model. The app conforms and injects.
public protocol RemoteRelayCommandRewriting: Sendable {
    /// Rewrites one newline-terminated CLI command line, mapping remote
    /// workspace/surface ID aliases to their local counterparts. Must return
    /// the input unchanged when no alias applies.
    func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data
}
