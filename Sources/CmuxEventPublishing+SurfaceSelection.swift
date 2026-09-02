import Foundation

extension CmuxEventBus {
    @discardableResult
    func publishSurfaceSelectionChanged(
        identity: SurfaceSelectionEventIdentity,
        snapshot: SurfaceSelectionEventSnapshot
    ) -> Bool {
        publish(
            name: Self.surfaceSelectionChangedEventName,
            category: "surface",
            source: "surface.selection",
            workspaceId: identity.workspaceId.uuidString,
            surfaceId: identity.surfaceId.uuidString,
            paneId: identity.paneId?.uuidString,
            windowId: identity.windowId?.uuidString,
            payload: snapshot.payload(identity: identity)
        )
    }
}
