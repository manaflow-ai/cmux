import Foundation

extension CmuxTuiSnapshotParser {
    /// Distinguishes a detached terminal from a unique existing view. Ambiguity and
    /// malformed snapshots fail closed; callers may not add a tab based on stale rows.
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated static func terminalPlacement(from data: Data, terminalID: String) async -> (placement: SurfaceRemotePlacement?, revision: String?)? {
        guard let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              authoritativeGraphIsValid(snapshot),
              let terminals = snapshot["terminals"] as? [[String: Any]],
              terminals.contains(where: { $0["id"] as? String == terminalID }),
              let allTabs = snapshot["tabs"] as? [[String: Any]] else { return nil }
        let tabs = allTabs.filter { $0["content_kind"] as? String == "terminal" && $0["content_id"] as? String == terminalID }
        guard tabs.count <= 1 else { return nil }
        guard let tab = tabs.first else { return (nil, resourceRevision(from: snapshot)) }
        guard let tabID = tab["id"] as? String,
              let paneID = tab["pane_id"] as? String,
              let panes = snapshot["panes"] as? [[String: Any]],
              let screenID = panes.first(where: { $0["id"] as? String == paneID })?["screen_id"] as? String,
              let screens = snapshot["screens"] as? [[String: Any]],
              let workspaceID = screens.first(where: { $0["id"] as? String == screenID })?["workspace_id"] as? String else { return nil }
        return (SurfaceRemotePlacement(workspaceID: workspaceID, tabID: tabID, cursor: CloudVMCursor(snapshot: snapshot)), resourceRevision(from: snapshot))
    }

    /// The mutation returns the exact created/moved tab. Never infer a new tab from
    /// a later resource snapshot, where another client may already have added a view.
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated static func placedTab(
        from data: Data,
        at target: CloudTuiTerminalProjectionTarget,
        tabID: String? = nil,
        terminalID: String? = nil
    ) async -> SurfaceRemotePlacement? {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cursor = mutationCursor(fromResult: envelope),
              let value = envelope["value"] as? [String: Any],
              let id = value["id"] as? String, !id.isEmpty,
              value["pane_id"] as? String == target.paneID,
              tabID == nil || tabID == id,
              terminalID == nil || (value["content_id"] as? String == terminalID
                  && value["content_kind"] as? String == "terminal") else { return nil }
        return SurfaceRemotePlacement(workspaceID: target.workspaceID, tabID: id, cursor: cursor)
    }

    /// Resolves an exact tab through its pane and screen for a revision-fenced close.
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated static func tabPlacement(from data: Data, tabID: String) async -> (workspaceID: String?, revision: String)? {
        guard let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              authoritativeGraphIsValid(snapshot),
              let revision = resourceRevision(from: snapshot),
              let tabs = snapshot["tabs"] as? [[String: Any]],
              let panes = snapshot["panes"] as? [[String: Any]],
              let screens = snapshot["screens"] as? [[String: Any]] else { return nil }
        guard let tab = tabs.first(where: { $0["id"] as? String == tabID }) else { return (nil, revision) }
        guard let paneID = tab["pane_id"] as? String,
              let screenID = panes.first(where: { $0["id"] as? String == paneID })?["screen_id"] as? String,
              let workspaceID = screens.first(where: { $0["id"] as? String == screenID })?["workspace_id"] as? String
        else { return nil }
        return (workspaceID, revision)
    }

    /// `terminalProjectionTarget(from:)` held to one workspace: its focused screen and pane
    /// (explicit indexes first, daemon order otherwise), appended after that pane's tabs.
    /// nil when the workspace is not in the snapshot or has no live pane.
    static func projectionTarget(from snapshot: [String: Any], inWorkspace workspaceID: String) -> CloudTuiTerminalProjectionTarget? {
        guard authoritativeGraphIsValid(snapshot),
              let workspaces = snapshot["workspaces"] as? [[String: Any]],
              workspaces.contains(where: { ($0["id"] as? String) == workspaceID }) else { return nil }
        let screens = snapshot["screens"] as? [[String: Any]] ?? []
        let panes = snapshot["panes"] as? [[String: Any]] ?? []
        let tabs = snapshot["tabs"] as? [[String: Any]] ?? []
        var tabCountByPane: [String: Int] = [:]
        for tab in tabs {
            if let paneID = tab["pane_id"] as? String, !paneID.isEmpty {
                tabCountByPane[paneID, default: 0] += 1
            }
        }
        let workspaceScreens = orderedSnapshotRows(
            screens.filter { ($0["workspace_id"] as? String) == workspaceID },
            focusedFirst: true
        )
        for screenEntry in workspaceScreens {
            guard let screenID = screenEntry.element["id"] as? String, !screenID.isEmpty else { continue }
            let screenPanes = orderedSnapshotRows(
                panes.filter { ($0["screen_id"] as? String) == screenID },
                focusedFirst: true
            )
            for paneEntry in screenPanes {
                guard let paneID = paneEntry.element["id"] as? String, !paneID.isEmpty else { continue }
                return CloudTuiTerminalProjectionTarget(
                    workspaceID: workspaceID,
                    screenID: screenID,
                    paneID: paneID,
                    index: tabCountByPane[paneID] ?? 0
                )
            }
        }
        return nil
    }

    /// An explicit workspace is authoritative: a missing destination fails closed.
    /// Only an unbound viewer falls back to the daemon-focused workspace.
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated static func terminalProjectionTarget(
        from data: Data,
        preferringWorkspace workspaceID: String?
    ) async -> (target: CloudTuiTerminalProjectionTarget, revision: String?)? {
        guard let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              authoritativeGraphIsValid(snapshot) else { return nil }
        let destination: CloudTuiTerminalProjectionTarget?
        if let workspaceID {
            destination = projectionTarget(from: snapshot, inWorkspace: workspaceID)
        } else {
            destination = terminalProjectionTarget(from: snapshot)
        }
        guard let target = destination else { return nil }
        return (target, resourceRevision(from: snapshot))
    }
}
