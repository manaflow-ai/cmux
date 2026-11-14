#if os(iOS)
import Foundation
import GhosttyNextKit

/// What woke a terminal page, by source, since the app started: each of the
/// screen's display links' frames, the frames asked of Ghostty's renderer,
/// and the renderer's own counters (its display link, timers and frames,
/// summed over the live surfaces). The energy bench's terminal cases log it
/// (`ListStressRig`), so a page that ticks with nothing to draw names its
/// source. Main thread; a counter is one dictionary add per wake.
@MainActor
enum TerminalWakeCounts {
    enum Source: String, CaseIterable {
        case outputLink = "output-link"
        case followFallback = "follow-fallback"
        case glide
        case fling
        case autoscroll
        case tuiMomentum = "tui-momentum"
        case drawRequest = "draw-request"
        case drawNow = "draw-now"
        case present
    }

    private static var counts: [Source: Int] = [:]
    /// Every surface made, while it lives (the renderer counters' sum).
    private static let surfaces = NSHashTable<TerminalSurfaceView>.weakObjects()

    static func count(_ source: Source) { counts[source, default: 0] += 1 }

    static func register(_ surface: TerminalSurfaceView) { surfaces.add(surface) }

    /// Every counter by name: the page's sources, then Ghostty's
    /// (`ghostty-frames`, `ghostty-draw-now` for its display link's ticks, ...).
    static func snapshot() -> [String: UInt64] {
        var out: [String: UInt64] = [:]
        for source in Source.allCases { out[source.rawValue] = UInt64(counts[source] ?? 0) }
        var ghostty = ghostty_surface_render_counters_s()
        for view in surfaces.allObjects {
            guard let surface = view.surface else { continue }
            let c = ghostty_surface_render_counters(surface)
            ghostty.frames += c.frames
            ghostty.renderer_wakeups += c.renderer_wakeups
            ghostty.renderer_draw_now += c.renderer_draw_now
            ghostty.renderer_cursor_timer_fires += c.renderer_cursor_timer_fires
            ghostty.renderer_animation_timer_fires += c.renderer_animation_timer_fires
            ghostty.io_wakeups += c.io_wakeups
            ghostty.io_timer_fires += c.io_timer_fires
        }
        out["ghostty-frames"] = ghostty.frames
        out["ghostty-wakeups"] = ghostty.renderer_wakeups
        out["ghostty-draw-now"] = ghostty.renderer_draw_now
        out["ghostty-cursor-timer"] = ghostty.renderer_cursor_timer_fires
        out["ghostty-animation-timer"] = ghostty.renderer_animation_timer_fires
        out["ghostty-io-wakeups"] = ghostty.io_wakeups
        out["ghostty-io-timer"] = ghostty.io_timer_fires
        return out
    }

    /// `after` minus `before`, by name, as `name=N` sorted by name.
    static func delta(_ before: [String: UInt64], _ after: [String: UInt64]) -> String {
        after.keys.sorted().map { "\($0)=\((after[$0] ?? 0) &- (before[$0] ?? 0))" }.joined(separator: " ")
    }
}
#endif
