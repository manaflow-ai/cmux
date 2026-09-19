import Foundation

/// A Cloud provider can author a native new-tab/split intent in the daemon's
/// layout before the resulting terminal is projected back to the Mac.
@MainActor
protocol SurfaceLayoutTerminalCreating: SurfaceProvider {
    func createTerminal(nearTabID: String, splitDirection: SurfaceSplitDirection?) async throws -> SurfaceResource
    func createTerminal(nearTabID: String, splitDirection: SurfaceSplitDirection?, request: CloudTerminalCreationRequest) async throws -> SurfaceResource
    func createTerminal(
        nearTabID: String,
        splitDirection: SurfaceSplitDirection?,
        cwd: String?,
        request: CloudTerminalCreationRequest
    ) async throws -> SurfaceResource
}

extension SurfaceLayoutTerminalCreating {
    func createTerminal(nearTabID: String, splitDirection: SurfaceSplitDirection?, request: CloudTerminalCreationRequest) async throws -> SurfaceResource {
        try await createTerminal(nearTabID: nearTabID, splitDirection: splitDirection, cwd: nil, request: request)
    }

    func createTerminal(
        nearTabID: String,
        splitDirection: SurfaceSplitDirection?,
        cwd: String?,
        request: CloudTerminalCreationRequest
    ) async throws -> SurfaceResource {
        try await createTerminal(nearTabID: nearTabID, splitDirection: splitDirection)
    }

    func createTerminal(
        nearTabID: String,
        splitDirection: SurfaceSplitDirection?,
        cwd: String? = nil
    ) async throws -> SurfaceResource {
        try await createTerminal(
            nearTabID: nearTabID,
            splitDirection: splitDirection,
            cwd: cwd,
            request: CloudTerminalCreationRequest()
        )
    }
}
