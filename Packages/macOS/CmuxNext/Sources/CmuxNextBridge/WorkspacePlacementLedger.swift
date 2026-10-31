package import CmuxNextDaemon

/// Placement state retained between a workspace create and its first sidebar document row.
/// The app owns one ledger per window manager and supplies its live-machine lookup when pruning.
@MainActor
package final class WorkspacePlacementLedger {
    /// Workspaces whose daemon create already applied the requested placement.
    package var placedByDaemon: Set<String> = []

    /// Neighbours used until the sidebar document places each new workspace.
    package var anchors: [String: SidebarDocSections.UnplacedAnchor] = [:]

    /// Group anchors armed only when the daemon accepts placement on create.
    package var groupAnchors: [String: SidebarDocSections.UnplacedAnchor] = [:]

    package init() {}

    /// Arms the first-frame anchor only when the daemon can place the create by the same rule.
    package func sending(_ rule: NewWorkspaceDefaultSlot?, key: WorkspaceKey,
                         on connection: DaemonConnection) async -> NewWorkspaceDefaultSlot? {
        guard let rule else { return nil }
        guard await connection.identity?.supports(DaemonCapability.workspaceCreateCurrent.rawValue) == true else { return nil }
        placedByDaemon.insert(key.rawValue)
        if let anchor = groupAnchors.removeValue(forKey: key.rawValue) { anchors[key.rawValue] = anchor }
        return rule
    }

    /// Releases all placement state when a create ends without a listed workspace.
    package func forget(_ id: String) {
        placedByDaemon.remove(id)
        anchors[id] = nil
        groupAnchors[id] = nil
    }

    /// Reads the first-frame anchor, pruning settled or vanished rows through injected live lookups.
    package func unplacedAnchor(for id: String, hasDocumentItem: (String) -> Bool,
                                workspaceExists: (String) -> Bool) -> SidebarDocSections.UnplacedAnchor? {
        guard !anchors.isEmpty else { return nil }
        if anchors.count > 16 {
            anchors = anchors.filter { key, _ in
                !hasDocumentItem(key) && (workspaceExists(key) || placedByDaemon.contains(key))
            }
        }
        return anchors[id]
    }
}
