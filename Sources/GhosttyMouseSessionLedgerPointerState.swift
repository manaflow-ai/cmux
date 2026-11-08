import AppKit
import GhosttyKit

extension GhosttyMouseSessionLedger {
    /// Last pointer location and modifiers observed for the active surface.
    struct PointerState {
        let localPoint: NSPoint
        let surfacePoint: NSPoint
        let mods: ghostty_input_mods_e
    }
}
