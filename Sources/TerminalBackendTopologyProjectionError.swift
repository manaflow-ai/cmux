import Foundation

/// A canonical topology shape the current Swift workspace model cannot project safely.
enum TerminalBackendTopologyProjectionError: Error, Equatable, Sendable {
    case unsupportedSurfaceKind(surfaceID: UUID, kind: String)
    case missingPane(UUID)
    case missingSurface(UUID)
    case duplicatePlacement(TerminalBackendTopologyPlacement)
    case projectionFailed(String)
}
