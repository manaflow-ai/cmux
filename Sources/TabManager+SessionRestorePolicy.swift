import Foundation

extension TabManager {
    static func isCloudVMSessionRestoreWorkspace(_ snapshot: SessionWorkspaceSnapshot) -> Bool {
        isManagedCloudVMSessionRestoreWorkspace(snapshot)
    }

    static func isManagedCloudVMSessionRestoreWorkspace(_ snapshot: SessionWorkspaceSnapshot) -> Bool {
        guard let managedCloudVMID = snapshot.remote?.managedCloudVMID else { return false }
        return !managedCloudVMID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
