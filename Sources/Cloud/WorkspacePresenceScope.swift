import Foundation

/// Computes the stable presence key shared by Mac clients viewing one workspace.
///
/// Cloud-bound workspaces use the daemon workspace id together with their VM id;
/// local workspaces use their persisted UUID. The prefix keeps the two namespaces
/// from colliding when a local UUID happens to resemble a remote id.
enum WorkspacePresenceScope {
    static func identifier(for workspace: Workspace?) -> String? {
        guard let workspace else { return nil }
        if let binding = workspace.cloudVMBinding,
           let remote = binding.remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !remote.isEmpty {
            return "cloud:\(MobileHostIdentity.deviceID()):\(remote)"
        }
        return "local:\(MobileHostIdentity.deviceID()):\(workspace.id.uuidString.lowercased())"
    }
}
