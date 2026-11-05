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
        seen.remove(id)
        groupAnchors[id] = nil
    }

    /// Anchored workspaces some store has listed: one gone after that was closed before its document item came.
    private var seen: Set<String> = []

    /// Reads the first-frame anchor. An anchor lasts until its workspace's document item exists (the document places
    /// it), or its workspace, once listed, is gone; never by count: a count prune dropped the anchor of a create not
    /// sent yet (no workspace, not `placedByDaemon`), so its row listed at the end for a hop, then moved.
    package func unplacedAnchor(for id: String, hasDocumentItem: (String) -> Bool,
                                workspaceExists: (String) -> Bool) -> SidebarDocSections.UnplacedAnchor? {
        guard !anchors.isEmpty else { return nil }
        var ended: [String] = []
        for key in anchors.keys {
            if hasDocumentItem(key) { ended.append(key) } else if workspaceExists(key) { seen.insert(key) } else if seen.contains(key) { ended.append(key) }
        }
        for key in ended { anchors[key] = nil; seen.remove(key) }
        return anchors[id]
    }
}
