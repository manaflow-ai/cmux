import CmuxMobileRPC
import Foundation

/// Decodes a remote workspace-list payload and projects it into Hive's
/// immutable workspace snapshot.
struct HiveRemoteWorkspaceDecoder: Sendable {
    /// Decode one mobile workspace-list response.
    func decode(_ data: Data) throws -> [HiveRemoteWorkspace] {
        let response = try MobileSyncWorkspaceListResponse.decode(data)
        return response.workspaces.map { workspace in
            HiveRemoteWorkspace(
                id: workspace.id,
                title: workspace.title,
                isSelected: workspace.isSelected,
                terminals: workspace.terminals.map {
                    HiveRemoteWorkspace.Terminal(
                        id: $0.id,
                        title: $0.title,
                        isFocused: $0.isFocused
                    )
                }
            )
        }
    }
}
