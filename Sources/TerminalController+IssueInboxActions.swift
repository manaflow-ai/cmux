import AppKit
import CmuxIssueInbox
import Foundation

extension TerminalController {
    func issueInboxListPayload() -> [String: Any] {
        issueInboxStore.loadCachedStateIfNeeded()
        let snapshot = issueInboxStore.snapshot()
        return [
            "items": snapshot.items.map(issueInboxItemPayload),
            "source_errors": issueInboxStore.sourceErrors,
            "fetched_at": snapshot.fetchedAt.mapValues(issueInboxISODate),
        ]
    }

    func issueInboxRefreshPayload() async -> V2CallResult {
        issueInboxStore.loadCachedStateIfNeeded()
        let report = await issueInboxStore.refresh()
        let perSource = report.perSource.mapValues { result -> [String: Any] in
            if let count = result.count {
                return ["count": count]
            }
            return ["error": result.error ?? "Unknown error"]
        }
        return .ok([
            "ok": true,
            "per_source": perSource,
        ])
    }

    func issueInboxOpen(params: [String: Any], forceFocus: Bool = false) -> V2CallResult {
        let target = issueInboxTargetWorkspace(params: params)
        switch target {
        case .failure(let error):
            return error
        case .success(let resolved):
            let shouldFocus = forceFocus || Self.socketCommandAllowsInAppFocusMutations()
            if shouldFocus {
                issueInboxSelectWorkspace(resolved.workspace, in: resolved.tabManager)
            }
            guard let panel = resolved.workspace.openOrFocusIssueInboxSurface(focus: shouldFocus) else {
                return .err(code: "internal_error", message: "Failed to open Issue Inbox", data: nil)
            }
            let windowId = v2ResolveWindowId(tabManager: resolved.tabManager)
            return .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": resolved.workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: resolved.workspace.id),
                "surface_id": panel.id.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
            ])
        }
    }

    func issueInboxSpawnWorkspace(
        issueID: String,
        cwd: String?,
        params: [String: Any],
        forceFocus: Bool = false
    ) -> V2CallResult {
        issueInboxStore.loadCachedStateIfNeeded()
        guard let item = issueInboxStore.item(issueID: issueID) else {
            return .err(code: "not_found", message: "Issue not found", data: ["issue_id": issueID])
        }

        let shouldFocus = forceFocus || Self.socketCommandAllowsInAppFocusMutations()
        if let workspaceID = issueInboxStore.spawnedWorkspace(issueID: issueID),
           let live = issueInboxLiveWorkspace(workspaceID) {
            if shouldFocus {
                issueInboxSelectWorkspace(live.workspace, in: live.tabManager)
            }
            return .ok([
                "reused": true,
                "workspace_id": workspaceID.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceID),
            ])
        }

        let explicitCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectory = (explicitCwd?.isEmpty == false ? explicitCwd : nil)
            ?? issueInboxStore.projectRoot(for: item)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workingDirectory, !workingDirectory.isEmpty else {
            return .err(
                code: "invalid_params",
                message: "issues.spawn_workspace requires cwd or a configured projectRoot",
                data: ["issue_id": issueID]
            )
        }

        var createParams = params
        createParams["title"] = issueInboxWorkspaceTitle(for: item)
        createParams["working_directory"] = workingDirectory
        createParams["description"] = "\(item.title)\n\(item.sourceURL.absoluteString)"
        createParams["workspace_env"] = [
            "CMUX_ISSUE_ID": item.id,
            "CMUX_ISSUE_URL": item.sourceURL.absoluteString,
            "CMUX_ISSUE_TITLE": item.title,
            "CMUX_ISSUE_PROVIDER": item.provider.rawValue,
        ]
        createParams["focus"] = true
        let createResult = v2WorkspaceCreate(params: createParams)
        switch createResult {
        case .err:
            return createResult
        case .ok(let payload):
            guard var object = payload as? [String: Any],
                  let rawWorkspaceID = object["workspace_id"] as? String,
                  let workspaceID = UUID(uuidString: rawWorkspaceID) else {
                return .err(code: "internal_error", message: "Workspace create returned no workspace_id", data: nil)
            }
            issueInboxStore.recordSpawnedWorkspace(issueID: item.id, workspaceID: workspaceID)
            if shouldFocus,
               let live = issueInboxLiveWorkspace(workspaceID) {
                issueInboxSelectWorkspace(live.workspace, in: live.tabManager)
            }
            object["reused"] = false
            return .ok(object)
        }
    }

    private struct IssueInboxWorkspaceTarget {
        let tabManager: TabManager
        let workspace: Workspace
    }

    private enum IssueInboxWorkspaceTargetResult {
        case success(IssueInboxWorkspaceTarget)
        case failure(V2CallResult)
    }

    private func issueInboxTargetWorkspace(params: [String: Any]) -> IssueInboxWorkspaceTargetResult {
        if v2HasNonNullParam(params, "workspace_id"), v2UUID(params, "workspace_id") == nil {
            return .failure(.err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil))
        }
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .failure(.err(code: "unavailable", message: "TabManager not available", data: nil))
        }
        let workspace: Workspace?
        if let workspaceID = v2UUID(params, "workspace_id") {
            workspace = tabManager.tabs.first { $0.id == workspaceID }
        } else {
            workspace = tabManager.selectedWorkspace
        }
        guard let workspace else {
            return .failure(.err(code: "not_found", message: "Workspace not found", data: nil))
        }
        return .success(IssueInboxWorkspaceTarget(tabManager: tabManager, workspace: workspace))
    }

    private func issueInboxLiveWorkspace(_ workspaceID: UUID) -> IssueInboxWorkspaceTarget? {
        guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            return nil
        }
        return IssueInboxWorkspaceTarget(tabManager: tabManager, workspace: workspace)
    }

    private func issueInboxSelectWorkspace(_ workspace: Workspace, in tabManager: TabManager) {
        if let windowId = AppDelegate.shared?.windowId(for: tabManager) {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            setActiveTabManager(tabManager)
        }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
    }

    private func issueInboxItemPayload(_ item: IssueInboxItem) -> [String: Any] {
        [
            "id": item.id,
            "provider": item.provider.rawValue,
            "source_url": item.sourceURL.absoluteString,
            "title": item.title,
            "status": item.status.rawValue,
            "provider_state": v2OrNull(item.providerState),
            "updated_at": issueInboxISODate(item.updatedAt),
            "repo_or_project": item.repoOrProject,
            "number": item.number,
            "assignees": item.assignees,
            "labels": item.labels,
        ]
    }

    private func issueInboxWorkspaceTitle(for item: IssueInboxItem) -> String {
        let base = "\(item.number) \(item.title)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard base.count > 60 else { return base }
        let prefix = base.prefix(57).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix)..."
    }

    private func issueInboxISODate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
