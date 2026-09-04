import Foundation

/// A panel's supported, unsupported, or temporarily unavailable selection state.
public nonisolated enum SurfaceSelectionReadResult: Equatable, Sendable {
    /// A successfully captured selection snapshot, including an empty state.
    case snapshot(SurfaceSelectionSnapshot)

    /// A panel kind that has no meaningful text-selection capability.
    case unsupported

    /// A supported panel whose live backing view could not be read.
    case unavailable
}
