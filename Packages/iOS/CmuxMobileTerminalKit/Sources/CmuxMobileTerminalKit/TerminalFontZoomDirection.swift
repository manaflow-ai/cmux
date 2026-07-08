import Foundation

/// Direction of a one-step terminal font-size zoom.
public enum TerminalFontZoomDirection: Equatable, Sendable {
    /// Shrink the font one step.
    case decrease
    /// Grow the font one step.
    case increase

    /// The libghostty binding-action string for a single zoom step.
    ///
    /// Used by the engine layer to drive `ghostty_surface_binding_action`.
    public var bindingAction: String {
        switch self {
        case .decrease:
            return "decrease_font_size:1"
        case .increase:
            return "increase_font_size:1"
        }
    }
}
