import Foundation

/// Outcome of decoding the private terminal-to-surface resolver response.
enum CloudTuiResolvedSurface: Equatable, Sendable {
    case surface(UInt64)
    case noPlacement
    case malformed
}
