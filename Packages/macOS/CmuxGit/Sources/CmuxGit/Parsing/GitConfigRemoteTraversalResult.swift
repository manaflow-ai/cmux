import Foundation

/// Bounded remote parsing output with an explicit completeness signal.
struct GitConfigRemoteTraversalResult: Sendable {
    let output: String?
    let isComplete: Bool
    let isUnsafe: Bool
}
