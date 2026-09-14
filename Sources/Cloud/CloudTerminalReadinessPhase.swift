import Foundation

/// Lifecycle phases for one Cloud terminal presentation transaction.
enum CloudTerminalReadinessPhase: Equatable, Sendable {
    case idle
    case waiting
    case ready
    case ended
}
