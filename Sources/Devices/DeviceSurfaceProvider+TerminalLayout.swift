import CmuxCore
import CmuxSurfaceCatalogModel
import Foundation

extension DeviceSurfaceProvider: SurfaceLayoutTerminalCreating {
    func createTerminal(nearTabID: String, splitDirection: SurfaceSplitDirection?) async throws -> SurfaceResource {
        try await createTerminal(nearTabID: nearTabID, splitDirection: splitDirection, request: CloudTerminalCreationRequest())
    }

    /// The source Mac creates the native split before its terminal is projected here.
    func createTerminal(
        nearTabID: String,
        splitDirection: SurfaceSplitDirection?,
        request: CloudTerminalCreationRequest
    ) async throws -> SurfaceResource {
        guard link.isConnected else { throw DeviceLinkError.notConnected }
        let sourceID = SurfaceResourceID(machine: machine, kind: .terminal, key: nearTabID)
        guard let source = catalog.resources[sourceID], let workspace = source.remoteWorkspace else {
            throw SurfaceCatalogError.unknownResource(sourceID)
        }
        request.bind(remoteWorkspaceID: workspace.id)
        var params: [String: Any] = [
            "workspace_id": workspace.id, "source_surface_id": nearTabID,
            "request_id": request.id.uuidString
        ]
        if let splitDirection { params["direction"] = splitDirection.rawValue }
        let response = try await link.request("device.workspace.terminal.create", params: params)
        guard let terminalID = response["created_terminal_id"] as? String, UUID(uuidString: terminalID) != nil else {
            throw DeviceLinkError.malformedResponse("device.workspace.terminal.create")
        }
        await link.fetchNow()
        let id = SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)
        if let resource = catalog.resources[id] {
            bindReservation(request: request, workspaceID: workspace.id, resource: resource)
            acceptSnapshot(response)
            publish()
            return resource
        }
        // The create receipt is authoritative even when metadata arrives on
        // the next delta. It must not trigger a second terminal creation.
        let resource = SurfaceResource(id: id, title: "", detail: nil, lifecycle: .launching, agent: nil,
            remoteWorkspace: workspace, remoteViews: [SurfaceRemoteView(tabID: terminalID, workspace: workspace)],
            port: nil, url: nil)
        catalog.upsert(resource, from: self)
        bindReservation(request: request, workspaceID: workspace.id, resource: resource)
        acceptSnapshot(response)
        publish()
        return resource
    }

    private func bindReservation(request: CloudTerminalCreationRequest, workspaceID: String, resource: SurfaceResource) {
        _ = layoutSync.bindCreatedTerminal(requestID: request.id, remoteWorkspaceID: workspaceID, resource: resource)
    }

    private func acceptSnapshot(_ response: [String: Any]) {
        guard let object = response["snapshot"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: object),
              let snapshot = try? JSONDecoder().decode(DeviceWorkspaceLayoutSnapshot.self, from: data) else { return }
        layoutSync.accept(snapshot)
    }
}
