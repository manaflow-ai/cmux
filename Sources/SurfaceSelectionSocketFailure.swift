import Foundation

/// Immutable socket error captured while resolving or reading a surface selection.
nonisolated struct SurfaceSelectionSocketFailure: Sendable {
    let code: String
    let message: String
    let data: [String: String]?
}
