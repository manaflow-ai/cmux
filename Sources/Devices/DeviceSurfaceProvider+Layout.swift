import CmuxCloud
import CmuxCore
import Foundation

extension DeviceSurfaceProvider: SurfaceProjectionLayoutProviding {
    func projectionLayout(workspaceID: String) async throws -> SurfaceProjectionLayout? {
        await link.fetchNow()
        guard link.isConnected,
              let record = link.mirror.workspaces.orderedRecords.first(where: { $0.id == workspaceID }) else { return nil }
        let data = try await link.requestData("device.workspace.layout", params: ["workspace_id": workspaceID])
        let snapshot: DeviceWorkspaceLayoutSnapshot
        do { snapshot = try JSONDecoder().decode(DeviceWorkspaceLayoutSnapshot.self, from: data) }
        catch { throw DeviceLinkError.malformedResponse("device.workspace.layout") }
        guard snapshot.workspaceID == workspaceID else {
            throw DeviceLinkError.malformedResponse("device.workspace.layout")
        }
        layoutSync.accept(snapshot)
        publish()
        return DeviceWorkspaceProjection(machine: machine, isLive: true).projectionLayout(record, layout: snapshot.layout)
    }
}

extension DeviceSurfaceProvider: SurfaceProjectionMutationObserving {
    func beginProjectionMutation(_ token: UUID) { layoutSync.beginMutation(token) }
    func endProjectionMutation(_ token: UUID) { layoutSync.endMutation(token) }
}
