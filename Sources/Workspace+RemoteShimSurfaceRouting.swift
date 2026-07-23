import Foundation

struct RemoteShimRespawnRewrite: Equatable {
    let command: String
    let sessionID: String
}

extension Workspace {
    /// Reroutes shim/relay respawns of remote-tracked surfaces onto a fresh
    /// daemon-owned pty session on the remote host. nil = surface is local;
    /// caller proceeds with the ordinary local respawn.
    func remoteShimRespawnRewrite(panelId: UUID, rawCommand: String) -> RemoteShimRespawnRewrite? {
        nil // red commit: not implemented
    }
}
