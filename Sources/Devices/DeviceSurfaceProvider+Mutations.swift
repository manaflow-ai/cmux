import CMUXMobileCore
import Foundation

/// The mutation half of ``DeviceSurfaceProvider``: every verb the Cloud tree,
/// the socket, and the CLI share (New Terminal, New Workspace, Close, Rename,
/// Kill) maps to one mobile-plane RPC on the remote Mac, then a re-sync so the
/// catalog reflects the authoritative result rather than an optimistic guess.
extension DeviceSurfaceProvider {
    private func currentWorkspaceID() -> String? {
        let records = link.mirror.workspaces.orderedRecords
        return records.first(where: \.isSelected)?.id ?? records.first?.id
    }

    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        guard command?.isEmpty != false, cwd == nil, name == nil else {
            throw SurfaceCatalogError.unsupported(String(localized: "devices.create.customCommandUnsupported", defaultValue: "Custom terminal options are not supported when creating a terminal on another Mac."))
        }
        guard link.isConnected else { throw DeviceLinkError.notConnected }
        let trimmed = remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workspaceID = (trimmed?.isEmpty == false ? trimmed : nil) ?? currentWorkspaceID() else {
            throw SurfaceCatalogError.destinationNotFound("a workspace on \(record.displayName)")
        }
        let response = try await link.request("mobile.terminal.create", params: ["workspace_id": workspaceID])
        guard let terminalID = response["created_terminal_id"] as? String else {
            throw DeviceLinkError.malformedResponse("mobile.terminal.create")
        }
        await link.fetchNow()
        publish()
        let id = SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)
        if let resource = catalog.resources[id] { return resource }
        // The delta has not landed yet: report the terminal from the create
        // reply so the caller can project it; the next sync fills in the rest.
        let workspace = link.mirror.workspaces.orderedRecords.first { $0.id == workspaceID }
            .map(DeviceWorkspaceProjection.remoteWorkspace)
            ?? SurfaceRemoteWorkspace(id: workspaceID, name: "", index: 0, focused: false)
        let resource = SurfaceResource(
            id: id,
            title: name ?? "",
            detail: cwd,
            lifecycle: .launching,
            agent: nil,
            remoteWorkspace: workspace,
            remoteViews: [SurfaceRemoteView(tabID: terminalID, workspace: workspace)],
            port: nil,
            url: nil
        )
        catalog.upsert(resource, from: self)
        return resource
    }

    func createRemoteWorkspace(name: String?) async throws -> SurfaceRemoteWorkspace {
        guard link.isConnected else { throw DeviceLinkError.notConnected }
        var params: [String: Any] = ["focus": false]
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["title"] = name
        }
        let response = try await link.request("workspace.create", params: params)
        guard let workspaceID = (response["created_workspace_id"] as? String) ?? (response["workspace_id"] as? String) else {
            throw DeviceLinkError.malformedResponse("workspace.create")
        }
        await link.fetchNow()
        publish()
        if let record = link.mirror.workspaces.orderedRecords.first(where: { $0.id == workspaceID }) {
            return DeviceWorkspaceProjection.remoteWorkspace(record)
        }
        return SurfaceRemoteWorkspace(id: workspaceID, name: name ?? "", index: link.mirror.workspaces.orderedRecords.count, focused: false)
    }

    func closeRemoteWorkspace(id: String) async throws {
        guard link.isConnected else { throw DeviceLinkError.notConnected }
        _ = try await link.request("workspace.close", params: ["workspace_id": id])
        await link.fetchNow()
        publish()
    }

    func renameRemoteWorkspace(id: String, name: String) async throws {
        guard link.isConnected else { throw DeviceLinkError.notConnected }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = trimmed.isEmpty ? "clear_name" : "rename"
        var params: [String: Any] = ["action": action, "workspace_id": id]
        if !trimmed.isEmpty { params["title"] = trimmed }
        _ = try await link.request("workspace.action", params: params)
        await link.fetchNow()
        publish()
    }

    /// A device terminal has exactly one placement (its pane), so a tab rename
    /// and a terminal rename are the same host verb.
    func renameRemoteTab(id: String, name: String) async throws {
        try await renameTerminalSurface(surfaceID: id, name: name)
    }

    func renameTerminal(_ id: SurfaceResourceID, name: String) async throws {
        try await renameTerminalSurface(surfaceID: id.key, name: name)
    }

    private func renameTerminalSurface(surfaceID: String, name: String) async throws {
        guard link.isConnected else { throw DeviceLinkError.notConnected }
        _ = try await link.request("mobile.terminal.rename", params: [
            "surface_id": surfaceID,
            "title": name.trimmingCharacters(in: .whitespacesAndNewlines),
        ])
        await link.fetchNow()
        publish()
    }

    func closeTerminal(_ id: SurfaceResourceID) async throws {
        guard link.isConnected else { throw DeviceLinkError.notConnected }
        _ = try await link.request("mobile.terminal.close", params: ["surface_id": id.key])
        for (panelID, session) in sessions where session.remoteSurfaceID.uuidString.lowercased() == id.key.lowercased() {
            session.stop()
            sessions[panelID] = nil
        }
        await link.fetchNow()
        publish()
    }
}
