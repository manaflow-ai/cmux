import AppKit
import Foundation

// MARK: - Mobile workspace list (iOS-facing payloads)
//
// The phone's `workspace.list` surface: enumerating workspaces across windows,
// serializing the workspace and group-section payloads, and the mobile-gated
// group collapse/expand handler. Lives in its own file so the mobile list
// payload code stays together without growing TerminalController.swift.
extension TerminalController {
    /// Mobile-gated collapse/expand of a workspace group. P1 group support on
    /// iOS is display-only: the phone renders collapsible group sections and can
    /// toggle a section open/closed, but cannot create, rename, or restructure
    /// groups. This requires an explicit, resolvable `group_id` (it must never
    /// fall back to the Mac's selected group) and delegates to the same
    /// `v2WorkspaceGroupSetCollapsed` the CLI and sidebar use, so the mutation
    /// path stays shared. `v2ResolveTabManager` routes by `group_id` to the
    /// owning window even in the multi-window case.
    func v2MobileWorkspaceGroupSetCollapsed(params: [String: Any], isCollapsed: Bool) -> V2CallResult {
        guard v2HasNonNullParam(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        guard v2UUID(params, "group_id") != nil else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        return v2WorkspaceGroupSetCollapsed(params: params, isCollapsed: isCollapsed)
    }

    func v2MobileWorkspaceList(
        params: [String: Any],
        tabManager resolvedTabManager: TabManager? = nil,
        createdWorkspaceID: String? = nil,
        createdTerminalID: String? = nil
    ) -> V2CallResult {
        let requestedWorkspaceID = v2UUID(params, "workspace_id")
        if v2HasNonNullParam(params, "workspace_id"), requestedWorkspaceID == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let requestedTerminalID: UUID?
        switch mobileTerminalAliasUUID(params: params) {
        case .missing:
            requestedTerminalID = nil
        case let .value(terminalID):
            requestedTerminalID = terminalID
        case .invalid:
            return .err(code: "invalid_params", message: "Missing or invalid terminal_id", data: nil)
        case .conflict:
            return .err(code: "invalid_params", message: "Conflicting terminal identifiers", data: nil)
        }

        // The phone shows workspaces from *every* open Mac window. Enumerate all
        // registered main windows and flatten their workspaces into one list,
        // but only when the caller has not named a specific target. When a
        // `workspace_id`, `window_id`, terminal alias, or an explicit
        // `resolvedTabManager` (the create/terminal-create paths pass one) is
        // present, keep today's single-window scoped behavior so those requests
        // resolve exactly the named target.
        let scopeToSingleWindow = resolvedTabManager != nil
            || requestedWorkspaceID != nil
            || v2HasNonNullParam(params, "window_id")
            || requestedTerminalID != nil

        // `is_selected` has no single answer across multiple windows. Mark only
        // the frontmost/key window's selected workspace as selected; in the old
        // single-window path this is exactly the one selected workspace. Using
        // `currentScriptableMainWindow()` (not `isKeyWindow`) means a backgrounded
        // app, where no window is key, still reports the same selection the old
        // path would have, instead of marking nothing selected.
        let selectedWorkspaceID = scopeToSingleWindow
            ? nil
            : AppDelegate.shared?.currentScriptableMainWindow()?.tabManager.selectedTabId

        let workspaces: [[String: Any]]
        // Group sections shown on the phone. Aggregated alongside the workspace
        // list so the iOS client can fold contiguous same-group workspaces under a
        // collapsible header that mirrors the Mac sidebar.
        var groups: [[String: Any]] = []
        if scopeToSingleWindow {
            guard let tabManager = resolvedTabManager ?? v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
            }
            // Only include groups when listing the whole window. A request scoped
            // to one workspace or terminal is a targeted lookup (create/refresh of
            // a single entry), not a sidebar render, so it omits group sections to
            // keep the response minimal. The phone always lists the full window.
            if requestedWorkspaceID == nil, requestedTerminalID == nil {
                groups = mobileWorkspaceGroupPayloads(tabManager.workspaceGroups, tabs: tabManager.tabs)
            }
            let visibleWorkspaces = requestedWorkspaceID.map { workspaceID in
                tabManager.tabs.filter { $0.id == workspaceID }
            } ?? tabManager.tabs
            if let requestedWorkspaceID, visibleWorkspaces.isEmpty {
                return .err(
                    code: "not_found",
                    message: "Workspace not found",
                    data: ["workspace_id": requestedWorkspaceID.uuidString]
                )
            }
            let scopedWorkspaces = visibleWorkspaces.map { workspace in
                mobileWorkspacePayload(
                    workspace: workspace,
                    isSelected: workspace.id == tabManager.selectedTabId,
                    requestedTerminalID: requestedTerminalID
                )
            }
            if let requestedTerminalID,
               !scopedWorkspaces.contains(where: { workspace in
                   guard let terminals = workspace["terminals"] as? [[String: Any]] else { return false }
                   return terminals.contains { ($0["id"] as? String) == requestedTerminalID.uuidString }
               }) {
                return .err(
                    code: "not_found",
                    message: "Terminal not found",
                    data: ["surface_id": requestedTerminalID.uuidString]
                )
            }
            workspaces = scopedWorkspaces
        } else {
            guard let app = AppDelegate.shared else {
                return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
            }
            var flattened: [[String: Any]] = []
            // `listMainWindowSummaries()` already dedupes window ids, but guard
            // against the same window or workspace appearing twice anyway: a
            // workspace lives in exactly one window, and ids are globally unique.
            var seenWindowIDs: Set<UUID> = []
            var seenWorkspaceIDs: Set<UUID> = []
            // Groups are per-TabManager (per window). Aggregate them in the same
            // window-iteration order the workspaces are flattened in, so a group's
            // header lands at its first member's position in the combined list.
            var aggregatedGroups: [[String: Any]] = []
            for summary in app.listMainWindowSummaries() {
                guard seenWindowIDs.insert(summary.windowId).inserted else { continue }
                guard let windowTabManager = app.tabManagerFor(windowId: summary.windowId) else { continue }
                aggregatedGroups.append(
                    contentsOf: mobileWorkspaceGroupPayloads(
                        windowTabManager.workspaceGroups,
                        tabs: windowTabManager.tabs
                    )
                )
                for workspace in windowTabManager.tabs where seenWorkspaceIDs.insert(workspace.id).inserted {
                    flattened.append(
                        mobileWorkspacePayload(
                            workspace: workspace,
                            isSelected: workspace.id == selectedWorkspaceID,
                            requestedTerminalID: requestedTerminalID
                        )
                    )
                }
            }
            workspaces = flattened
            groups = aggregatedGroups
        }

        var payload: [String: Any] = [
            "workspaces": workspaces,
            "groups": groups
        ]
        if let createdWorkspaceID {
            payload["created_workspace_id"] = createdWorkspaceID
        }
        if let createdTerminalID {
            payload["created_terminal_id"] = createdTerminalID
        }
        return .ok(payload)
    }

    /// Serializes one workspace into the iOS-facing mobile workspace list shape.
    ///
    /// Shared by the single-window (scoped) and all-windows enumeration branches
    /// of `v2MobileWorkspaceList` so the two never diverge. When
    /// `requestedTerminalID` is non-nil the terminals array is filtered to that
    /// one terminal (only the scoped branch passes it; the all-windows branch
    /// always passes nil, so it lists every terminal). The scoped
    /// terminal-not-found check is enforced by the caller after the list is built.
    func mobileWorkspacePayload(
        workspace: Workspace,
        isSelected: Bool,
        requestedTerminalID: UUID?
    ) -> [String: Any] {
        let terminals = mobileTerminalPanels(in: workspace).compactMap { terminal -> [String: Any]? in
            if let requestedTerminalID, terminal.id != requestedTerminalID {
                return nil
            }
            return [
                "id": terminal.id.uuidString,
                "title": workspace.panelTitle(panelId: terminal.id) ?? terminal.displayTitle,
                "current_directory": v2OrNull(
                    mobileNonEmpty(workspace.panelDirectories[terminal.id])
                        ?? mobileNonEmpty(terminal.directory)
                        ?? mobileNonEmpty(terminal.requestedWorkingDirectory)
                ),
                "is_ready": terminal.surface.surface != nil,
                "is_focused": terminal.id == workspace.focusedPanelId
            ]
        }

        return [
            "id": workspace.id.uuidString,
            "title": workspace.title,
            "current_directory": v2OrNull(mobileNonEmpty(workspace.currentDirectory)),
            "is_selected": isSelected,
            "is_pinned": workspace.isPinned,
            // Group membership so the phone can fold contiguous same-group
            // workspaces under their group header. nil for ungrouped workspaces.
            "group_id": v2OrNull(workspace.groupId?.uuidString),
            "terminals": terminals
        ]
    }

    /// Serializes the window's workspace groups into the iOS-facing mobile shape.
    ///
    /// A subset of `v2WorkspaceGroupPayload` carrying only what the phone needs to
    /// render collapsible sections (no v2 handle refs, color, or icon). Member ids
    /// are taken in `tabs` spatial order so the phone's grouping matches the Mac.
    /// Membership is resolved with a single pass over `tabs` (not a scan per
    /// group), keeping this synchronous RPC path linear on large workspace sets.
    func mobileWorkspaceGroupPayloads(_ groups: [WorkspaceGroup], tabs: [Workspace]) -> [[String: Any]] {
        guard !groups.isEmpty else { return [] }
        var memberIDsByGroup: [UUID: [String]] = [:]
        for workspace in tabs {
            guard let groupId = workspace.groupId else { continue }
            memberIDsByGroup[groupId, default: []].append(workspace.id.uuidString)
        }
        return groups.map { group in
            [
                "id": group.id.uuidString,
                "name": group.name,
                "is_collapsed": group.isCollapsed,
                "is_pinned": group.isPinned,
                "anchor_workspace_id": group.anchorWorkspaceId.uuidString,
                "member_workspace_ids": memberIDsByGroup[group.id] ?? []
            ]
        }
    }
}
