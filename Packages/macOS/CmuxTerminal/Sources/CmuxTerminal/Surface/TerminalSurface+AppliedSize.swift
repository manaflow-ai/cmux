internal import GhosttyKit
#if DEBUG
internal import CMUXDebugLog
#endif

extension TerminalSurface {
    /// Applies one renderer/PTY size mutation through the observable owner boundary.
    @MainActor
    func applySurfaceSize(
        _ surface: ghostty_surface_t,
        width: UInt32,
        height: UInt32,
        caller: StaticString
    ) {
        #if DEBUG
        let previous = ghostty_surface_size(surface)
        #endif

        ghostty_surface_set_size(surface, width, height)

        #if DEBUG
        let applied = ghostty_surface_size(surface)
        logDebugEvent(
            "surface.size.apply surface=\(id.uuidString.prefix(8)) caller=\(caller) " +
            "grid=\(previous.columns)x\(previous.rows)->\(applied.columns)x\(applied.rows) " +
            "pixels=\(previous.width_px)x\(previous.height_px)->\(applied.width_px)x\(applied.height_px) " +
            "target=\(width)x\(height)"
        )
        #endif
    }
}
