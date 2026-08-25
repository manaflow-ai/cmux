import CmuxTerminal
import Foundation
import GhosttyKit

/// Immutable data captured from one Ghostty pointer callback.
///
/// SAFETY: The request crosses only between the callback ingress actor and the
/// main actor. Its C enum is an immutable integer-shaped ABI value.
struct GhosttyPointerStyleIngressRequest: @unchecked Sendable {
    enum Event: @unchecked Sendable {
        case activate
        case retire(UUID?)
        case runtimeReset
        case runtimeEnded
        case shape(ghostty_action_mouse_shape_e)
        case linkHover(Bool)

        @MainActor
        func terminalEvent(runtimeLifetimeId: UUID) -> TerminalPointerStyleEvent? {
            switch self {
            case .activate, .retire(_):
                return nil
            case .runtimeReset:
                return .runtimeReset(runtimeLifetimeId)
            case .runtimeEnded:
                return .runtimeEnded(runtimeLifetimeId)
            case .shape(let shape):
                return .ghosttyShape(
                    shape,
                    runtimeLifetimeId: runtimeLifetimeId
                )
            case .linkHover(let active):
                return .ghosttyLinkHoverChanged(
                    active,
                    runtimeLifetimeId: runtimeLifetimeId
                )
            }
        }
    }

    let event: Event
    let surfaceId: UUID
    let runtimeLifetimeId: UUID
    var sequence: UInt64 = 0
}
