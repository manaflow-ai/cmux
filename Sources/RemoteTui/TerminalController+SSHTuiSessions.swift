import Foundation

extension TerminalController {
    /// Compatibility CLI verbs read the authoritative cmux-tui graph, never a second PTY registry.
    @MainActor
    func tuiSSHSessions(params: [String: Any]) async -> V2CallResult? {
        let selection = v2RequestedRemotePTYWorkspaceID(params: params)
        if let error = selection.error { return error }
        let all = params["all_workspaces"] as? Bool ?? false
        if all && selection.workspaceId != nil {
            return v2WorkspaceRemotePTYSessions(params: params)
        }
        let workspaces: [Workspace]
        if all {
            workspaces = AppDelegate.shared?.scriptableMainWindows().flatMap { $0.tabManager.tabs }.filter(\.usesSSHTui) ?? []
        } else if let id = selection.workspaceId, let workspace = Workspace.liveWorkspace(id: id) {
            guard workspace.usesSSHTui else { return nil }
            workspaces = [workspace]
        } else if let workspace = tabManager?.selectedWorkspace, workspace.usesSSHTui {
            workspaces = [workspace]
        } else {
            return nil
        }
        guard !workspaces.isEmpty else { return nil }
        var sessions: [[String: Any]] = []
        var errors: [[String: Any]] = []
        var listedMachines = Set<SurfaceMachineID>()
        let catalog = SurfaceCatalog.shared
        for workspace in workspaces {
            guard let configuration = workspace.remoteConfiguration,
                  let coordinator = AppDelegate.shared?.sshTuiWorkspaceCoordinator else { continue }
            do {
                let provider = try coordinator.provider(connection: SSHTuiConnection(configuration: configuration))
                if all, !listedMachines.insert(provider.machine).inserted { continue }
                guard await provider.refreshCurrentGraph(force: false) else {
                    throw CloudMachineLink.LinkError.spawnFailed(provider.info.linkError ?? CloudDiagnosticFailure.network.label)
                }
                let remoteWorkspace = workspace.cloudVMBinding?.remoteWorkspaceID
                for resource in catalog.authoritativeSnapshot.resources(on: provider.machine) where resource.kind == .terminal {
                    guard all || resource.isDetachedTerminal || remoteWorkspace.map({ id in resource.remoteWorkspaces.contains { $0.id == id } }) == true
                            || catalog.projections(of: resource.id).contains(where: { $0.workspaceID == workspace.id }) else { continue }
                    let owner = all ? workspaces.first(where: { candidate in
                        guard candidate.cloudVMBinding?.vmID == provider.machine.rawValue,
                              let remote = candidate.cloudVMBinding?.remoteWorkspaceID else { return false }
                        return resource.remoteWorkspaces.contains { $0.id == remote }
                    }) ?? workspace : workspace
                    sessions.append([
                        "session_id": resource.id.key, "resource": resource.id.rawValue, "backend": "cmux-tui",
                        "workspace_id": owner.id.uuidString, "workspace_title": owner.title,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: owner.id),
                        "running": resource.lifecycle == .running || resource.lifecycle == .launching,
                        "title": resource.title, "cwd": resource.detail ?? "",
                    ])
                }
            } catch {
                errors.append(["workspace_id": workspace.id.uuidString, "error": CloudMachineLink.errorText(error)])
            }
        }
        return .ok(["backend": "cmux-tui", "all_workspaces": all, "workspace_count": workspaces.count,
                    "sessions": sessions, "errors": errors])
    }

    /// Combines disjoint owner lists without hiding a backend's errors or empty workspaces.
    nonisolated func mergeRemotePTYSessionLists(tui: V2CallResult, legacy: V2CallResult) -> V2CallResult {
        guard case .ok(let tuiRaw) = tui else { return tui }
        guard case .ok(let legacyRaw) = legacy else { return legacy }
        guard let tuiPayload = tuiRaw as? [String: Any],
              let legacyPayload = legacyRaw as? [String: Any] else {
            return .err(code: "internal_error", message: CloudDiagnosticFailure.response.localizedDescription, data: nil)
        }
        // Typed locals keep this literal cheap for the type checker; the inline
        // `as? ?? +` form timed out on slower CI runners.
        let tuiCount: Int = tuiPayload["workspace_count"] as? Int ?? 0
        let legacyCount: Int = legacyPayload["workspace_count"] as? Int ?? 0
        let tuiSessions: [[String: Any]] = tuiPayload["sessions"] as? [[String: Any]] ?? []
        let legacySessions: [[String: Any]] = legacyPayload["sessions"] as? [[String: Any]] ?? []
        let tuiErrors: [[String: Any]] = tuiPayload["errors"] as? [[String: Any]] ?? []
        let legacyErrors: [[String: Any]] = legacyPayload["errors"] as? [[String: Any]] ?? []
        let merged: [String: Any] = [
            "all_workspaces": true,
            "workspace_count": tuiCount + legacyCount,
            "sessions": tuiSessions + legacySessions,
            "errors": tuiErrors + legacyErrors,
        ]
        return .ok(merged)
    }

    @MainActor
    func tuiSSHSessionAttachResolve(params: [String: Any]) async -> V2CallResult? {
        guard let sessionID = params["session_id"] as? String, sessionID.hasPrefix("term_") else { return nil }
        var query = params
        query.removeValue(forKey: "session_id")
        if query["workspace_id"] == nil { query["all_workspaces"] = true }
        guard let result = await tuiSSHSessions(params: query), case .ok(let raw) = result,
              let payload = raw as? [String: Any], let sessions = payload["sessions"] as? [[String: Any]],
              let match = sessions.first(where: { $0["session_id"] as? String == sessionID }) else {
            return .err(code: "not_found", message: String(localized: "ssh.tui.sessionNotFound", defaultValue: "This SSH terminal is no longer available."), data: nil)
        }
        return .ok(match)
    }

    @MainActor
    func closeTuiSSHSession(params: [String: Any]) async -> V2CallResult? {
        guard let sessionID = params["session_id"] as? String, sessionID.hasPrefix("term_") else { return nil }
        guard let resolved = await tuiSSHSessionAttachResolve(params: params) else { return nil }
        guard case .ok(let raw) = resolved,
              let payload = raw as? [String: Any],
              let key = payload["resource"] as? String, let resource = SurfaceResourceID(rawValue: key),
              let provider = SurfaceCatalog.shared.provider(for: resource.machine) else { return resolved }
        do {
            try await provider.closeTerminal(resource)
            return .ok(["session_id": sessionID, "closed": true, "backend": "cmux-tui"])
        } catch {
            return .err(code: "remote_pty_error", message: CloudMachineLink.errorText(error), data: nil)
        }
    }
}
