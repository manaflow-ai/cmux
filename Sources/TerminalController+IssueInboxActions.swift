import AppKit
import CmuxIssueInbox
import CmuxWorkspaces
import Foundation

extension TerminalController {
    func issueInboxListPayload() -> [String: Any] {
        issueInboxStore.loadCachedStateIfNeeded()
        let snapshot = issueInboxStore.snapshot()
        return [
            "items": snapshot.items.map(issueInboxItemPayload),
            "source_errors": issueInboxStore.sourceErrors,
            "fetched_at": snapshot.fetchedAt.mapValues(issueInboxISODate),
            "refreshing": Array(issueInboxStore.refreshing).sorted(),
            "config": issueInboxConfigPayload(),
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

    func issueInboxOpenConfigPayload() -> V2CallResult {
        let url = issueInboxStore.configURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                let stub = """
                {
                  "sources": [
                    {
                      "type": "github",
                      "repo": "manaflow-ai/cmux",
                      "projectRoot": "~/fun/cmuxterm-hq/repo",
                      "spawn": {
                        "devServerCommand": "cd web && bun dev",
                        "webURL": "http://localhost:3000",
                        "defaultAgent": "claude"
                      }
                    },
                    { "type": "linear", "teamKey": "ENG", "projectRoot": "~/dev/thing", "apiKeyEnvVar": "LINEAR_API_KEY" }
                  ],
                  "autoRefreshSeconds": 0
                }
                """
                try stub.data(using: .utf8)?.write(to: url, options: .atomic)
            }
            PreferredEditorService(defaults: .standard).open(url)
            return .ok(["path": url.path])
        } catch {
            return .err(
                code: "internal_error",
                message: "Failed to open Issue Inbox config: \(error.localizedDescription)",
                data: ["path": url.path]
            )
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
        let requestedAgent: IssueSpawnAgent?
        switch issueInboxSpawnAgent(params) {
        case .success(let agent):
            requestedAgent = agent
        case .failure(let result):
            return result
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
        let plan = IssueSpawnPlanBuilder.build(
            item: item,
            sourceConfig: issueInboxStore.sourceConfig(for: item),
            workingDirectory: workingDirectory,
            requestedAgent: requestedAgent
        )

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
        if let initialCommand = plan.initialCommand {
            createParams["initial_command"] = initialCommand
        }
        if let layout = plan.layout {
            switch issueInboxLayoutJSONObject(layout) {
            case .success(let object):
                createParams["layout"] = object
            case .failure(let result):
                return result
            }
        }
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

    private func issueInboxConfigPayload() -> [String: Any] {
        [
            "path": issueInboxStore.configURL.path,
            "file_exists": issueInboxStore.configFileExists,
            "warnings": issueInboxStore.configWarnings.map { warning in
                [
                    "id": warning.id,
                    "message": warning.message,
                ]
            },
            "sources": issueInboxStore.sourceConfigs.map { source in
                [
                    "id": source.sourceID,
                    "display_name": source.displayName,
                    "provider": source.type.rawValue,
                    "project_root": v2OrNull(source.projectRoot),
                    "spawn": [
                        "dev_server_command": v2OrNull(source.spawn?.devServerCommand),
                        "web_url": v2OrNull(source.spawn?.webURL),
                        "default_agent": v2OrNull(source.spawn?.defaultAgent?.rawValue),
                    ],
                ]
            },
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
        Self.issueInboxISO8601Formatter.string(from: date)
    }

    private static let issueInboxISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private enum IssueInboxSpawnAgentParseResult {
        case success(IssueSpawnAgent?)
        case failure(V2CallResult)
    }

    private func issueInboxSpawnAgent(_ params: [String: Any]) -> IssueInboxSpawnAgentParseResult {
        guard v2HasNonNullParam(params, "agent") else {
            return .success(nil)
        }
        guard let raw = v2RawString(params, "agent")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let agent = IssueSpawnAgent(rawValue: raw) else {
            return .failure(.err(
                code: "invalid_params",
                message: "agent must be claude, codex, or none",
                data: ["agent": params["agent"] ?? ""]
            ))
        }
        return .success(agent)
    }

    private enum IssueInboxLayoutJSONObjectResult {
        case success([String: Any])
        case failure(V2CallResult)
    }

    private func issueInboxLayoutJSONObject(_ layout: IssueSpawnLayoutNode) -> IssueInboxLayoutJSONObjectResult {
        do {
            let data = try JSONEncoder().encode(layout)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.err(code: "internal_error", message: "Failed to encode issue layout", data: nil))
            }
            return .success(object)
        } catch {
            return .failure(.err(
                code: "internal_error",
                message: "Failed to encode issue layout: \(error.localizedDescription)",
                data: nil
            ))
        }
    }
}
