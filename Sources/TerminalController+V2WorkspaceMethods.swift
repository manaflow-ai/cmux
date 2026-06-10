import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - V2 workspace methods
extension TerminalController {
    private func v2WorkspaceSummaryPayload(
        workspace: Workspace,
        index: Int?,
        selected: Bool
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "id": workspace.id.uuidString,
            "ref": v2Ref(kind: .workspace, uuid: workspace.id),
            "title": workspace.title,
            "description": v2OrNull(workspace.customDescription),
            "selected": selected,
            "pinned": workspace.isPinned,
            "listening_ports": workspace.listeningPorts,
            "remote": workspace.remoteStatusPayload(),
            "current_directory": v2OrNull(workspace.currentDirectory),
            "custom_color": v2OrNull(workspace.customColor),
            "latest_conversation_message": v2OrNull(workspace.latestConversationMessage),
            "latest_submitted_message": v2OrNull(workspace.latestSubmittedMessage),
            "latest_submitted_at": v2OrNull(workspace.latestSubmittedAt.map(CmuxEventBus.isoTimestamp))
        ]
        if let index {
            payload["index"] = index
        }
        return payload
    }

    func v2WorkspaceList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var workspaces: [[String: Any]] = []
        v2MainSync {
            workspaces = tabManager.tabs.enumerated().map { index, ws in
                v2WorkspaceSummaryPayload(
                    workspace: ws,
                    index: index,
                    selected: ws.id == tabManager.selectedTabId
                )
            }
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspaces": workspaces
        ])
    }

    func v2WorkspaceCreate(
        params: [String: Any],
        tabManager resolvedTabManager: TabManager? = nil
    ) -> V2CallResult {
        guard let tabManager = resolvedTabManager ?? v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let requestedWorkingDirectory = v2RawString(params, "working_directory")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectory = (requestedWorkingDirectory?.isEmpty == false) ? requestedWorkingDirectory : nil

        let requestedInitialCommand = v2RawString(params, "initial_command")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialCommand = (requestedInitialCommand?.isEmpty == false) ? requestedInitialCommand : nil

        let rawInitialEnv = v2StringMap(params, "initial_env") ?? [:]
        let initialEnv = rawInitialEnv.reduce(into: [String: String]()) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            result[key] = pair.value
        }
        let cwd: String?
        if let workingDirectory {
            cwd = workingDirectory
        } else if let raw = params["cwd"] {
            guard let str = raw as? String else {
                return .err(code: "invalid_params", message: "cwd must be a string", data: nil)
            }
            cwd = str
        } else {
            cwd = nil
        }

        let requestedTitle = v2RawString(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (requestedTitle?.isEmpty == false) ? requestedTitle : nil
        let description = v2RawString(params, "description")

        // Decode optional layout param (same JSON schema as cmux.json layout field).
        // Validate before creating the workspace so malformed layouts fail fast.
        var layoutNode: CmuxLayoutNode?
        if let rawLayout = params["layout"] {
            guard JSONSerialization.isValidJSONObject(rawLayout),
                  let layoutData = try? JSONSerialization.data(withJSONObject: rawLayout) else {
                return .err(code: "invalid_params", message: "layout must be a valid JSON object", data: nil)
            }
            do {
                layoutNode = try JSONDecoder().decode(CmuxLayoutNode.self, from: layoutData)
            } catch {
                return .err(code: "invalid_params", message: "Invalid layout: \(error.localizedDescription)", data: nil)
            }
        }

        var newId: UUID?
        var initialSurfaceId: UUID?
        let shouldFocus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)
        let shouldEagerLoadTerminal = v2Bool(params, "eager_load_terminal") ?? !shouldFocus
        let shouldAutoRefreshMetadata = v2Bool(params, "auto_refresh_metadata") ?? true
        v2MainSync {
            let ws = tabManager.addWorkspace(
                title: title,
                workingDirectory: cwd,
                initialTerminalCommand: layoutNode == nil ? initialCommand : nil,
                initialTerminalEnvironment: layoutNode == nil ? initialEnv : [:],
                select: shouldFocus,
                eagerLoadTerminal: shouldEagerLoadTerminal,
                autoRefreshMetadata: shouldAutoRefreshMetadata
            )
            ws.setCustomDescription(description)
            if let layoutNode {
                ws.applyCustomLayout(layoutNode, baseCwd: cwd ?? ws.currentDirectory)
            }
            newId = ws.id
            initialSurfaceId = ws.focusedPanelId
        }

        guard let newId else {
            return .err(code: "internal_error", message: "Failed to create workspace", data: nil)
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": newId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: newId),
            "surface_id": v2OrNull(initialSurfaceId?.uuidString),
            "surface_ref": v2Ref(kind: .surface, uuid: initialSurfaceId)
        ])
    }
    func v2WorkspaceSelect(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let wsId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }

        var success = false
        v2MainSync {
            if let ws = tabManager.tabs.first(where: { $0.id == wsId }) {
                // If this workspace belongs to another window, bring it forward so focus is visible.
                if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                    _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                    setActiveTabManager(tabManager)
                }
                tabManager.selectWorkspace(ws)
                success = true
            }
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return success
            ? .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
            ])
            : .err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
            ])
    }
    func v2WorkspaceCurrent(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var wsId: UUID?
        var wsPayload: [String: Any]?
        v2MainSync {
            wsId = tabManager.selectedTabId
            if let wsId, let workspace = tabManager.tabs.first(where: { $0.id == wsId }) {
                let index = tabManager.tabs.firstIndex(where: { $0.id == wsId })
                wsPayload = v2WorkspaceSummaryPayload(
                    workspace: workspace,
                    index: index,
                    selected: true
                )
            }
        }
        guard let wsId else {
            return .err(code: "not_found", message: "No workspace selected", data: nil)
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": wsId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: wsId),
            "workspace": wsPayload ?? NSNull()
        ])
    }
    func v2WorkspaceClose(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let wsId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }

        var found = false
        var protected = false
        v2MainSync {
            if let ws = tabManager.tabs.first(where: { $0.id == wsId }) {
                guard tabManager.canCloseWorkspace(ws) else {
                    protected = true
                    found = true
                    return
                }
                tabManager.closeWorkspace(ws)
                found = true
            }
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        if protected {
            return .err(code: "protected", message: workspaceCloseProtectedMessage(), data: [
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId),
                "pinned": true
            ])
        }
        return found
            ? .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
            ])
            : .err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
            ])
    }

    func workspaceCloseProtectedMessage() -> String {
        String(
            localized: "workspace.closeProtected.message",
            defaultValue: "Pinned workspaces can't be closed while pinned. Unpin the workspace first."
        )
    }

    func v2WorkspaceMoveToWindow(params: [String: Any]) -> V2CallResult {
        guard let wsId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to move workspace", data: nil)
        v2MainSync {
            guard let srcTM = AppDelegate.shared?.tabManagerFor(tabId: wsId) else {
                result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": wsId.uuidString])
                return
            }
            guard let dstTM = AppDelegate.shared?.tabManagerFor(windowId: windowId) else {
                result = .err(code: "not_found", message: "Window not found", data: ["window_id": windowId.uuidString])
                return
            }
            guard let ws = srcTM.detachWorkspace(tabId: wsId) else {
                result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": wsId.uuidString])
                return
            }

            dstTM.attachWorkspace(ws, select: focus)
            if focus {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(dstTM)
            }
            result = .ok([
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId),
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        return result
    }
    func v2WorkspaceReorder(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }

        let index = v2Int(params, "index")
        let beforeId = v2UUID(params, "before_workspace_id")
        let afterId = v2UUID(params, "after_workspace_id")
        let dryRun = v2Bool(params, "dry_run") ?? false

        let targetCount = (index != nil ? 1 : 0) + (beforeId != nil ? 1 : 0) + (afterId != nil ? 1 : 0)
        if targetCount != 1 {
            return .err(
                code: "invalid_params",
                message: "Specify exactly one target: index, before_workspace_id, or after_workspace_id",
                data: nil
            )
        }

        var plan: WorkspaceReorderPlanItem?
        v2MainSync {
            if let index {
                plan = tabManager.workspaceReorderPlan(tabId: workspaceId, toIndex: index)
            } else {
                plan = tabManager.workspaceReorderPlan(tabId: workspaceId, before: beforeId, after: afterId)
            }
            if let plan, !dryRun {
                _ = tabManager.reorderWorkspace(tabId: workspaceId, toIndex: plan.toIndex)
            }
        }

        guard let plan else {
            return .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": workspaceId.uuidString])
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        var payload = v2WorkspaceReorderPlanPayload(plan, windowId: windowId)
        payload["dry_run"] = dryRun
        payload["index"] = plan.toIndex
        payload["plan"] = [v2WorkspaceReorderPlanPayload(plan, windowId: windowId)]
        payload["events"] = (!dryRun && plan.fromIndex != plan.toIndex)
            ? [v2WorkspaceReorderPlanPayload(plan, windowId: windowId)]
            : []
        return .ok(payload)
    }

    func v2WorkspaceReorderMany(params: [String: Any]) -> V2CallResult {
        let rawOrder = v2WorkspaceReorderManyOrder(params)
        if let invalid = rawOrder.invalidValue {
            return .err(
                code: "invalid_params",
                message: workspaceReorderManyInvalidWorkspaceMessage(),
                data: ["workspace": invalid]
            )
        }
        let order = rawOrder.order
        guard !order.isEmpty else {
            return .err(
                code: "invalid_params",
                message: workspaceReorderManyMissingOrderMessage(),
                data: nil
            )
        }

        var workspaceIds: [UUID] = []
        workspaceIds.reserveCapacity(order.count)
        for raw in order {
            guard let workspaceId = v2UUIDAny(raw) else {
                return .err(
                    code: "invalid_params",
                    message: workspaceReorderManyInvalidWorkspaceMessage(),
                    data: ["workspace": raw]
                )
            }
            workspaceIds.append(workspaceId)
        }

        guard let tabManager = v2ResolveWorkspaceReorderManyTabManager(params: params, workspaceIds: workspaceIds) else {
            return .err(code: "unavailable", message: workspaceReorderManyTabManagerUnavailableMessage(), data: nil)
        }

        let dryRun = v2Bool(params, "dry_run") ?? false
        let result = v2MainSync {
            tabManager.reorderWorkspaces(orderedWorkspaceIds: workspaceIds, dryRun: dryRun)
        }

        let plans: [WorkspaceReorderPlanItem]
        switch result {
        case .success(let planned):
            plans = planned
        case .failure(.duplicateWorkspace(let workspaceId)):
            return .err(
                code: "invalid_params",
                message: workspaceReorderManyDuplicateWorkspaceMessage(),
                data: [
                    "workspace_id": workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId)
                ]
            )
        case .failure(.workspaceNotFound(let workspaceId)):
            return .err(
                code: "not_found",
                message: workspaceReorderManyWorkspaceNotFoundMessage(),
                data: [
                    "workspace_id": workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId)
                ]
            )
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        let planPayloads = plans.map { v2WorkspaceReorderPlanPayload($0, windowId: windowId) }
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "dry_run": dryRun,
            "plan": planPayloads,
            "events": dryRun ? [] : planPayloads.filter { item in
                (item["from_index"] as? Int) != (item["to_index"] as? Int)
            }
        ])
    }

    private func v2ResolveWorkspaceReorderManyTabManager(params: [String: Any], workspaceIds: [UUID]) -> TabManager? {
        if v2HasNonNullParam(params, "window_id") {
            return v2ResolveTabManager(params: params)
        }
        for workspaceId in workspaceIds {
            if let owner = v2ResolveWorkspaceOwner(workspaceId) {
                return owner
            }
        }
        return v2ResolveTabManager(params: params)
    }

    private func v2WorkspaceReorderManyOrder(_ params: [String: Any]) -> (order: [String], invalidValue: String?) {
        if let raw = params["workspace_ids"], !(raw is NSNull) {
            if let workspaceIds = raw as? [String] {
                return v2NormalizeWorkspaceReorderManyOrder(workspaceIds)
            }
            if let workspaceIds = raw as? [Any] {
                var strings: [String] = []
                strings.reserveCapacity(workspaceIds.count)
                for item in workspaceIds {
                    guard let stringItem = item as? String else {
                        return ([], v2WorkspaceReorderManyInvalidValueDescription(
                            item,
                            fallback: "<invalid_workspace_id>"
                        ))
                    }
                    strings.append(stringItem)
                }
                return v2NormalizeWorkspaceReorderManyOrder(strings)
            }
            if let workspaceId = raw as? String {
                return v2NormalizeWorkspaceReorderManyOrder([workspaceId])
            }
            return ([], v2WorkspaceReorderManyInvalidValueDescription(
                raw,
                fallback: "<invalid_workspace_ids>"
            ))
        }

        guard let order = params["order"], !(order is NSNull) else { return ([], nil) }
        guard let orderString = order as? String else {
            return ([], v2WorkspaceReorderManyInvalidValueDescription(
                order,
                fallback: "<invalid_order_value>"
            ))
        }
        let refs = orderString
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return v2NormalizeWorkspaceReorderManyOrder(refs)
    }

    private func v2NormalizeWorkspaceReorderManyOrder(_ rawItems: [String]) -> (order: [String], invalidValue: String?) {
        var order: [String] = []
        order.reserveCapacity(rawItems.count)
        for raw in rawItems {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return ([], raw)
            }
            order.append(trimmed)
        }
        return (order, nil)
    }

    private func v2WorkspaceReorderManyInvalidValueDescription(
        _ value: Any,
        fallback: String
    ) -> String {
        guard JSONSerialization.isValidJSONObject(["value": value]),
              let data = try? JSONSerialization.data(withJSONObject: ["value": value], options: []),
              let encoded = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return encoded
    }

    private func v2WorkspaceReorderPlanPayload(
        _ plan: WorkspaceReorderPlanItem,
        windowId: UUID?
    ) -> [String: Any] {
        [
            "workspace_id": plan.workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: plan.workspaceId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "from_index": plan.fromIndex,
            "to_index": plan.toIndex
        ]
    }

    private func workspaceReorderManyMissingOrderMessage() -> String {
        String(
            localized: "socket.workspace.reorderMany.missingOrder",
            defaultValue: "Missing workspace_ids"
        )
    }

    private func workspaceReorderManyDuplicateWorkspaceMessage() -> String {
        String(
            localized: "socket.workspace.reorderMany.duplicateWorkspace",
            defaultValue: "Duplicate workspace in order"
        )
    }

    private func workspaceReorderManyWorkspaceNotFoundMessage() -> String {
        String(
            localized: "socket.workspace.reorderMany.workspaceNotFound",
            defaultValue: "Workspace not found"
        )
    }

    private func workspaceReorderManyInvalidWorkspaceMessage() -> String {
        String(
            localized: "socket.workspace.reorderMany.invalidWorkspace",
            defaultValue: "Invalid workspace id or ref"
        )
    }

    private func workspaceReorderManyTabManagerUnavailableMessage() -> String {
        String(
            localized: "socket.workspace.reorderMany.tabManagerUnavailable",
            defaultValue: "TabManager not available"
        )
    }

    func v2WorkspacePromptSubmit(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }

        let messageKeys = ["message", "prompt", "text", "body"]
        for key in messageKeys {
            guard let raw = params[key], !(raw is NSNull) else { continue }
            guard raw is String else {
                return .err(code: "invalid_params", message: "\(key) must be a string", data: nil)
            }
        }
        let message = messageKeys.lazy.compactMap { self.v2RawString(params, $0) }.first
        guard let tabManager = v2ResolveWorkspaceOwner(workspaceId) ?? v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let iMessageModeEnabled = IMessageModeSettings.isEnabled()
        var outcome: (messageRecorded: Bool, reordered: Bool, index: Int)?
        var preview: String?

        // Socket handlers run off the main thread; prompt submit mutates
        // @Published workspace/sidebar state and workspace ordering.
        v2MainSync {
            outcome = tabManager.handlePromptSubmit(
                workspaceId: workspaceId,
                message: message,
                iMessageModeEnabled: iMessageModeEnabled
            )
            preview = tabManager.tabs.first(where: { $0.id == workspaceId })?.latestSubmittedMessage
        }

        guard let outcome else {
            return .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": workspaceId.uuidString])
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "i_message_mode_enabled": iMessageModeEnabled,
            "message_recorded": outcome.messageRecorded,
            "message_preview": v2OrNull(preview),
            "reordered": outcome.reordered,
            "index": outcome.index
        ])
    }

    // MARK: - Workspace Groups (v2)

    func v2WorkspaceRename(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let titleRaw = v2String(params, "title"),
              !titleRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
        }

        let title = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        var renamed = false
        v2MainSync {
            guard tabManager.tabs.contains(where: { $0.id == workspaceId }) else { return }
            tabManager.setCustomTitle(tabId: workspaceId, title: title)
            renamed = true
        }

        guard renamed else {
            return .err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId)
            ])
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "title": title
        ])
    }
    func v2WorkspaceNext(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "No workspace selected", data: nil)
        v2MainSync {
            guard tabManager.selectedTabId != nil else { return }
            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }
            tabManager.selectNextTab()
            guard let workspaceId = tabManager.selectedTabId else { return }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        return result
    }

    func v2WorkspacePrevious(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "No workspace selected", data: nil)
        v2MainSync {
            guard tabManager.selectedTabId != nil else { return }
            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }
            tabManager.selectPreviousTab()
            guard let workspaceId = tabManager.selectedTabId else { return }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        return result
    }

    func v2WorkspaceLast(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "No previous workspace in history", data: nil)
        v2MainSync {
            guard let before = tabManager.selectedTabId else { return }
            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }
            tabManager.navigateBack()
            guard let after = tabManager.selectedTabId, after != before else { return }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "workspace_id": after.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: after),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        return result
    }

    func v2WorkspaceEqualizeSplits(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let orientationFilter = v2String(params, "orientation")

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let tree = ws.bonsplitController.treeSnapshot()
            let equalizeResult = SplitEqualizer.equalize(
                in: tree,
                controller: ws.bonsplitController,
                orientationFilter: orientationFilter
            )
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "equalized": equalizeResult.didFullyEqualize
            ])
        }
        return result
    }

}
