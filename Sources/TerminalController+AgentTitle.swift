import Bonsplit
import CmuxSettings
import Foundation

/// Agent callbacks name stable projections through the Cloud authority boundary.
extension TerminalController {
    /// `surface.sync_codex_native_title`: applies Codex's already-resolved
    /// native thread title to the panel's raw title tier, the same tier used
    /// by OSC terminal-title updates. The detached CLI hook owns the database
    /// read; this app-side handler only resolves the panel and mutates
    /// in-memory workspace state.
    /// Applies the title on the main actor for the asynchronous socket bridge.
    func v2SurfaceSyncCodexNativeTitle(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(
                code: "unavailable",
                message: String(
                    localized: "socket.surfaceSyncCodexNativeTitle.tabManagerUnavailable",
                    defaultValue: "TabManager not available"
                ),
                data: nil
            )
        }
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.surfaceSyncCodexNativeTitle.workspaceIdInvalid",
                    defaultValue: "Missing or invalid workspace_id"
                ),
                data: nil
            )
        }
        guard let panelId = v2UUID(params, "panel_id") else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.surfaceSyncCodexNativeTitle.panelIdInvalid",
                    defaultValue: "Missing or invalid panel_id"
                ),
                data: nil
            )
        }

        if v2Bool(params, "probe") == true {
            return v2MainSync { self.cloudNameProbe(workspaceId: workspaceId, panelId: panelId, manager: tabManager) }
        }
        guard let title = v2String(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.surfaceSyncCodexNativeTitle.invalidTitle",
                    defaultValue: "Missing or invalid title"
                ),
                data: nil
            )
        }
        var found = false
        var applied = false
        v2MainSync {
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
            let resolvedPanelId = workspace.panels[panelId] != nil
                ? panelId
                : workspace.panelIdFromSurfaceId(TabID(uuid: panelId))
            guard let resolvedPanelId else { return }
            found = true
            applied = SurfaceCatalog.shared.submitCloudPanelRename(
                workspace: workspace, panelID: resolvedPanelId, title: title, source: .auto,
                context: CloudAgentNameContext(wire: params["cloud_name_context"])
            ) ?? tabManager.updatePanelTitle(tabId: workspaceId, panelId: resolvedPanelId, title: title)
        }

        guard found else {
            return .err(
                code: "not_found",
                message: String(
                    localized: "socket.surfaceSyncCodexNativeTitle.panelNotFound",
                    defaultValue: "Panel not found"
                ),
                data: [
                    "workspace_id": workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId)
                ]
            )
        }
        return .ok(["applied": applied])
    }

    // MARK: - V2 Workspace Methods

    /// `workspace.set_auto_title`: applies an AI-generated title to a workspace
    /// (and optionally one of its panels/tabs) with `.auto` provenance, so a
    /// user-set title is never overwritten. Gated on the opt-in
    /// `workspaceAutoNamingEnabled` setting; `{"probe": true}` reads the live
    /// setting state without writing, which lets hook processes honor
    /// mid-session toggles. `panel_id` accepts either a panel UUID or a
    /// surface UUID.
    func v2WorkspaceSetAutoTitle(params: [String: Any]) -> V2CallResult {
        let enabled = AutomationCatalogSection().workspaceAutoNaming.value(in: .standard)
        if v2Bool(params, "probe") == true {
            let agentSlug = AutomationCatalogSection().autoNamingAgent.value(in: .standard)
            var result: [String: Any] = [
                "enabled": enabled,
                "summarizer_agent": v2OrNull(agentSlug == AutoNamingAgentCatalog.autoSlug ? nil : agentSlug)
            ]
            // With a workspace_id the probe also reports user ownership, so
            // naming engines can skip the LLM call entirely for workspaces
            // the user renamed.
            if let workspaceId = v2UUID(params, "workspace_id"),
               let tabManager = v2ResolveTabManager(params: params) {
                var userOwned: Bool?
                v2MainSync {
                    guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
                    userOwned = workspace.effectiveCustomTitleSource == .user
                }
                result["workspace_user_owned"] = v2OrNull(userOwned)
                if let panelId = v2UUID(params, "panel_id") {
                    v2MainSync {
                        if case .ok(let values) = self.cloudNameProbe(workspaceId: workspaceId, panelId: panelId, manager: tabManager),
                           let cloudValues = values as? [String: Any] {
                            result.merge(cloudValues) { _, new in new }
                        }
                    }
                }
            }
            return .ok(result)
        }
        guard enabled else {
            return .err(code: "disabled", message: "Workspace auto-naming is disabled in Settings", data: ["enabled": false])
        }
        // A naming pass reporting a problem (rate limit / out of tokens / signed
        // out / missing override binary). Recorded for the Settings status line
        // only — it never reaches a workspace or tab title.
        if let failure = v2String(params, "failure") {
            AutoNamingStatusStore.record(
                rawCategory: failure,
                agent: v2String(params, "agent") ?? "",
                at: Date().timeIntervalSince1970
            )
            return .ok(["recorded": true, "enabled": true])
        }
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
        let panelId = v2UUID(params, "panel_id")

        let title = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let panelOnlyIfMultiple = v2Bool(params, "panel_only_if_multiple") ?? false
        var found = false
        var workspaceApplied = false
        var panelApplied: Bool?
        v2MainSync {
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
            found = true
            workspaceApplied = tabManager.setCustomTitle(tabId: workspaceId, title: title, source: .auto)
            if let panelId {
                // Hook payloads carry surface ids; accept either a panel id
                // or a surface id for the tab target.
                let resolvedPanelId = workspace.panels[panelId] != nil
                    ? panelId
                    : workspace.panelIdFromSurfaceId(TabID(uuid: panelId))
                if let resolvedPanelId,
                   !(panelOnlyIfMultiple && workspace.panels.count < 2 && workspace.cloudVMBinding == nil) {
                    panelApplied = SurfaceCatalog.shared.submitCloudPanelRename(
                        workspace: workspace, panelID: resolvedPanelId, title: title, source: .auto,
                        context: CloudAgentNameContext(wire: params["cloud_name_context"])
                    ) ?? workspace.setPanelCustomTitle(panelId: resolvedPanelId, title: title, source: .auto)
                }
            }
        }

        guard found else {
            return .err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId)
            ])
        }

        // A title landed, so the naming agent is working again: clear any stale
        // failure the Settings status line may be showing.
        if workspaceApplied || panelApplied == true {
            AutoNamingStatusStore.clear()
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "title": title,
            "workspace_applied": workspaceApplied,
            "panel_applied": v2OrNull(panelApplied),
            "enabled": true
        ])
    }


    @MainActor
    private func cloudNameProbe(workspaceId: UUID, panelId: UUID, manager: TabManager) -> V2CallResult {
        guard let workspace = manager.workspacesById[workspaceId],
              let resolved = workspace.panels[panelId] != nil ? panelId : workspace.panelIdFromSurfaceId(TabID(uuid: panelId))
        else { return .ok([:]) }
        let context = SurfaceCatalog.shared.cloudAgentNameContext(workspaceID: workspaceId, panelID: resolved)
        return .ok(["cloud_name_context": v2OrNull(context?.wire)])
    }
}
