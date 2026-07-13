internal import CmuxTerminalCore
internal import GhosttyKit

struct MobileViewportLiveFontProbe {
    let surface: ghostty_surface_t

    func read() -> Float? {
        guard GhosttySurfaceRuntimeProbe.surfacePointerAppearsLive(surface) else { return nil }
        let points = ghostty_surface_font_size(surface)
        guard points.isFinite, points > 0 else { return nil }
        return points
    }
}
