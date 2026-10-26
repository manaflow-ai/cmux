import GhosttyNextKit

/// Where a terminal view's pointer events go (``TerminalSurfaceView/mouse``): its Ghostty surface
/// (``GhosttyMouseSink``), or a test's counter. Positions are in points with a top-left origin, as
/// Ghostty takes them (ghostty.h `ghostty_surface_mouse_*`).
protocol TerminalMouseSink: AnyObject {
    func position(x: Double, y: Double, mods: ghostty_input_mods_e)
    /// True when Ghostty consumed the button (the program has the mouse, or a link click).
    func button(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, mods: ghostty_input_mods_e) -> Bool
    func scroll(x: Double, y: Double, mods: ghostty_input_scroll_mods_t)
}

/// A view's Ghostty surface as its ``TerminalMouseSink``; with no surface (`ghostty_surface_new` failed)
/// every event goes nowhere. The view that owns this sink owns the surface, and frees it only in its deinit.
final class GhosttyMouseSink: TerminalMouseSink {
    private let surface: ghostty_surface_t?

    init(surface: ghostty_surface_t?) {
        self.surface = surface
    }

    func position(x: Double, y: Double, mods: ghostty_input_mods_e) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, x, y, mods)
    }

    func button(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, mods: ghostty_input_mods_e) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(surface, state, button, mods)
    }

    func scroll(x: Double, y: Double, mods: ghostty_input_scroll_mods_t) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }
}
