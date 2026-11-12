import Foundation

extension SurfaceResourceGroup {
    /// Uses the workspace's own name, falling back to the machine's friendly label.
    func localWorkspaceTitle(hostName: String) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? hostName : name
    }
}
