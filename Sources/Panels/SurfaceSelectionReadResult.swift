import Foundation

/// A panel's supported, unsupported, or temporarily unavailable selection state.
public nonisolated enum SurfaceSelectionReadResult: Equatable, Sendable {
    case snapshot(SurfaceSelectionSnapshot)
    case unsupported
    case unavailable
}
