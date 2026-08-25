public import Foundation
public import GhosttyKit

/// An input that can change the pointer presented by a terminal surface.
public enum TerminalPointerStyleEvent {
    /// A native surface lifetime is about to begin accepting output.
    case runtimeActivated(UUID)

    /// The current native surface lifetime ended and must ignore later callbacks.
    case runtimeEnded(UUID?)

    /// The child process exited while the native surface lifetime remains live.
    case runtimeReset(UUID)

    /// Ghostty requested a base pointer shape, including OSC 22 requests.
    case ghosttyShape(ghostty_action_mouse_shape_e, runtimeLifetimeId: UUID)

    /// Ghostty began or ended its OSC 8 hyperlink hover affordance.
    case ghosttyLinkHoverChanged(Bool, runtimeLifetimeId: UUID)

    /// The terminal surface gained or lost focus.
    case focusChanged(Bool)

    /// Cmux started or ended its Cmd-hover link affordance.
    case cmuxLinkHoverChanged(Bool)
}
