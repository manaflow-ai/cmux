import CmuxTerminal
import Foundation

/// Immutable data captured from one Ghostty pointer callback.
///
/// SAFETY: The request crosses only between the callback ingress actor and the
/// main actor. Its C enum is an immutable integer-shaped ABI value.
struct GhosttyPointerStyleIngressRequest: @unchecked Sendable {
    let event: GhosttyPointerStyleIngressEvent
    let surfaceId: UUID
    let runtimeLifetimeId: UUID
    var sequence: UInt64 = 0
    var lifecycleSequence: UInt64 = 0
    var focusGeneration: UInt64 = 0
    var runtimeGeneration: UInt64 = 0
}
