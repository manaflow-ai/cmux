public import GhosttyKit

/// An input that can change the pointer presented by a terminal surface.
public enum TerminalPointerStyleEvent {
    /// Ghostty requested a base pointer shape, including OSC 22 requests.
    case ghosttyShape(ghostty_action_mouse_shape_e)

    /// The terminal surface gained or lost focus.
    case focusChanged(Bool)

    /// Cmux started or ended its Cmd-hover link affordance.
    case cmuxLinkHoverChanged(Bool)

    /// The terminal process or protocol lifecycle returned to its default state.
    case reset
}
