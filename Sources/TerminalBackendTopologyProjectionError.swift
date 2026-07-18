import Foundation

/// A canonical topology shape the current Swift workspace model cannot project safely.
enum TerminalBackendTopologyProjectionError: Error, Equatable, Sendable {
    case multipleScreens(workspaceID: UUID, count: Int)
    case unsupportedSurfaceKind(surfaceID: UUID, kind: String)
    case missingPane(UUID)
    case missingSurface(UUID)
    case duplicatePlacement(TerminalBackendTopologyPlacement)
    case projectionFailed(String)
}
