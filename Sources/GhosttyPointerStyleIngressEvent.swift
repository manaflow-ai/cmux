import CmuxTerminal
import Foundation
import GhosttyKit

/// One immutable pointer-ingress transition captured from Ghostty.
///
/// SAFETY: The C enum is an immutable integer-shaped ABI value and is only
/// converted into a main-actor ``TerminalPointerStyleEvent`` at delivery.
enum GhosttyPointerStyleIngressEvent: @unchecked Sendable {
    case runtimeReset
    case runtimeEnded
    case shape(ghostty_action_mouse_shape_e)
    case linkHover(Bool)

    func terminalEvent(runtimeLifetimeId: UUID) -> TerminalPointerStyleEvent {
        switch self {
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
