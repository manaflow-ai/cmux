import CmuxSurfaceCatalogModel
import Foundation

/// A Cloud provider can author a native new-tab/split intent in the daemon's
/// layout before the resulting terminal is projected back to the Mac.
@MainActor
protocol SurfaceLayoutTerminalCreating: SurfaceProvider {
    func createTerminal(nearTabID: String, splitDirection: SurfaceSplitDirection?) async throws -> SurfaceResource
    func createTerminal(nearTabID: String, splitDirection: SurfaceSplitDirection?, request: CloudTerminalCreationRequest) async throws -> SurfaceResource
}

extension SurfaceLayoutTerminalCreating {
    func createTerminal(nearTabID: String, splitDirection: SurfaceSplitDirection?, request: CloudTerminalCreationRequest) async throws -> SurfaceResource {
        try await createTerminal(nearTabID: nearTabID, splitDirection: splitDirection)
    }
}
