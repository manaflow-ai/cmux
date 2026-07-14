internal import CmuxTerminalCore
internal import GhosttyKit

struct MobileViewportLiveFontProbe {
    let surface: ghostty_surface_t

    func read() -> MobileViewportLiveFont? {
        guard GhosttySurfaceRuntimeProbe.surfacePointerAppearsLive(surface) else { return nil }
        let points = ghostty_surface_font_size(surface)
        guard points.isFinite, points > 0 else { return nil }
        return MobileViewportLiveFont(
            pointSize: points,
            isAdjusted: ghostty_surface_font_size_adjusted(surface)
        )
    }
}
