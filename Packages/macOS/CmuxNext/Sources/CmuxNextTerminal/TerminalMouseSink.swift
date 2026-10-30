import GhosttyNextKit

/// Where a terminal view's pointer events go (``TerminalSurfaceView/mouse``): its Ghostty surface
/// (``GhosttyMouseSink``), or a test's counter. Positions are in points with a top-left origin, as
/// Ghostty takes them (ghostty.h `ghostty_surface_mouse_*`).
protocol TerminalMouseSink: AnyObject {
    func position(x: Double, y: Double, mods: ghostty_input_mods_e)
    /// True when Ghostty consumed the button (the program has the mouse, or a link click).
    func button(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, mods: ghostty_input_mods_e) -> Bool
    func scroll(x: Double, y: Double, mods: ghostty_input_scroll_mods_t)
    /// A force-touch stage and pressure at Ghostty's last pointer position.
    func pressure(stage: UInt32, pressure: Double)
}

/// A view's Ghostty surface as its ``TerminalMouseSink``; with no surface (`ghostty_surface_new` failed)
/// every event goes nowhere. The view that owns this sink owns the surface until its deinit hands it to
/// ``TerminalSurfaceTeardown``, which frees it later on main.
final class GhosttyMouseSink: TerminalMouseSink {
    /// SAFETY: the owning view's surface, freed only after that view's deinit (``TerminalSurfaceTeardown``),
    /// and the deinit releases this sink first; every event arrives on the main actor while the view lives.
    @safe private let surface: ghostty_surface_t?

    /// `surface` is the owning view's (TerminalSurfaceView.mouse).
    init(surface: ghostty_surface_t?) {
        // SAFETY: the owning view's surface, handed to this sink for the view's life (`surface`'s note).
        self.surface = unsafe surface
    }

    func position(x: Double, y: Double, mods: ghostty_input_mods_e) {
        guard let surface else { return }
        // SAFETY: the owning view's live surface (`surface`'s note).
        unsafe ghostty_surface_mouse_pos(surface, x, y, mods)
    }

    func button(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, mods: ghostty_input_mods_e) -> Bool {
        guard let surface else { return false }
        // SAFETY: as in position(x:y:mods:).
        return unsafe ghostty_surface_mouse_button(surface, state, button, mods)
    }

    func scroll(x: Double, y: Double, mods: ghostty_input_scroll_mods_t) {
        guard let surface else { return }
        // SAFETY: as in position(x:y:mods:).
        unsafe ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    func pressure(stage: UInt32, pressure: Double) {
        guard let surface else { return }
        // SAFETY: as in position(x:y:mods:).
        unsafe ghostty_surface_mouse_pressure(surface, stage, pressure)
    }
}
