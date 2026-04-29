import SwiftUI

struct WorkspaceLayoutView: View {
    let host: WorkspaceLayoutInteractionHandlers
    let renderSnapshot: WorkspaceLayoutRenderSnapshot
    let surfaceRegistry: any WorkspaceSurfaceRegistryProtocol

    /// Initialize with a workspace-owned host boundary and the canonical render snapshot.
    /// - Parameters:
    ///   - host: Workspace-owned AppKit host boundary
    ///   - renderSnapshot: The canonical snapshot resolved by the workspace runtime owner
    ///   - surfaceRegistry: Workspace-owned retained surface registry
    init(
        host: WorkspaceLayoutInteractionHandlers,
        renderSnapshot: WorkspaceLayoutRenderSnapshot,
        surfaceRegistry: any WorkspaceSurfaceRegistryProtocol
    ) {
        self.host = host
        self.renderSnapshot = renderSnapshot
        self.surfaceRegistry = surfaceRegistry
    }

    var body: some View {
        WorkspaceLayoutNativeHost(
            hostBridge: host,
            renderSnapshot: renderSnapshot,
            surfaceRegistry: surfaceRegistry
        )
    }
}
