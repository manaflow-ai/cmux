#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign
import GhosttyNextKit
import IOSurface

extension TerminalSurfaceView {
    /// Adds `motionSample` to `debug.motion`'s trace samplers, once: a static `let` runs its initializer one time (the
    /// first surface view reads it).
    static let motionSamplerRegistration: Void = MotionDebug.registeredSamplers.append(motionSample)

    /// `debug.motion` `trace_*` sampler (FRAME OWNER S4 defect (a): which present path drew each terminal frame in a
    /// drag): per display frame, each shown terminal surface as `terminal`:
    /// `[x, y, width, height, shown width px, shown height px, frames, off-main presents, fresh presents,
    /// display passes, main draws, late presents, owned, presenter, host frame]`.
    /// The rect is the surface layer in window points with a top-left origin (the committed model); `shown` is the
    /// IOSurface the layer shows (0 before the first frame); the counters are Ghostty's render counters, cumulative
    /// (a frame that went through main is one of `frames` that is neither an off-main nor a fresh present);
    /// `owned` is 1 once its window's commit owns its frame (every made surface, cmux-ad m19); `presenter` is
    /// ``TerminalFramePresenter/debugState(of:)`` (request, watch, commit or -); `host frame` is what
    /// `ghostty_surface_host_frame` answers now without presenting (owned only, else "-"). It reads only while the trace
    /// records; nothing runs when it does not.
    private static func drawnCols(_ surface: ghostty_surface_t) -> UInt64 {
        var cols: UInt16 = 0
        var rows: UInt16 = 0
        return ghostty_surface_drawn_grid(surface, &cols, &rows) ? UInt64(cols) : 0
    }

    /// RESIZE P0 10 diag (nomerge): the presenter's pass presented (1), found shown (2) or kept (3) this view's frame.
    func debugStampPresent(_ kind: UInt64) {
        guard let surface else { return }
        let counters = ghostty_surface_render_counters(surface)
        debugPresentStamp = [clock_gettime_nsec_np(CLOCK_UPTIME_RAW), kind, counters.frames, counters.renderer_draw_now,
                             lane?.debugParsedNanos.load(ordering: .relaxed) ?? 0,
                             lane?.debugLabelCols.load(ordering: .relaxed) ?? 0,
                             lane?.debugFramesAtParse.load(ordering: .relaxed) ?? 0, Self.drawnCols(surface)]
    }

    static func motionSample(_ view: NSView) -> [String: [Any]]? {
        guard let surfaceView = view as? TerminalSurfaceView else { return nil }
        guard let window = surfaceView.window, let surface = surfaceView.surface, !surfaceView.isHiddenOrHasHiddenAncestor,
              let layer = surfaceView.layer, let root = window.contentView?.layer else { return [:] }
        let rect = layer.convert(layer.bounds, to: root)
        let height = root.bounds.height
        let top = root.isGeometryFlipped ? rect.minY : height - rect.maxY
        func rounded(_ value: CGFloat) -> Double { (Double(value) * 100).rounded() / 100 }
        let shown = surfaceView.presentedFrame
        let counters = ghostty_surface_render_counters(surface)
        let owned = surfaceView.frameOwnership.embedderPresents
        let presenter = TerminalFramePresenter.forWindow(window).debugState(of: surfaceView)
        let row: [Any] = [rounded(rect.minX), rounded(top), rounded(rect.width), rounded(rect.height),
                          shown?.width ?? 0, shown?.height ?? 0,
                          counters.frames, counters.host_off_main_presents, counters.host_fresh_presents,
                          counters.host_display_passes, counters.host_main_draws, counters.host_late_presents,
                          owned ? 1 : 0, presenter, owned ? Self.name(surfaceView.hostFrame(present: false)) : "-",
                          // RESIZE P0 9 diag (nomerge): output queued / parsed uptime ns and bytes parsed (TerminalOutputLane)
                          surfaceView.lane?.debugQueuedNanos.load(ordering: .relaxed) ?? 0,
                          surfaceView.lane?.debugParsedNanos.load(ordering: .relaxed) ?? 0,
                          surfaceView.lane?.debugParsedBytes.load(ordering: .relaxed) ?? 0,
                          surfaceView.lane?.debugLabelCols.load(ordering: .relaxed) ?? 0,
                          // RESIZE P0 10 diag (nomerge), fields 19..: draw-now ticks, wakeups, drawn grid cols now,
                          // frames and draw-now ticks right after the last parse, the last present stamp
                          // [ns, kind 1 presented 2 shown 3 kept, frames, draw-now, parsed ns, label cols, frames at parse,
                          // drawn cols] and the last draw-ahead stamp [ns, frames, width px].
                          counters.renderer_draw_now, counters.renderer_wakeups, Self.drawnCols(surface),
                          surfaceView.lane?.debugFramesAtParse.load(ordering: .relaxed) ?? 0,
                          surfaceView.lane?.debugDrawNowAtParse.load(ordering: .relaxed) ?? 0,
                          surfaceView.debugPresentStamp, surfaceView.debugAheadStamp]
        return ["terminal": [row]]
    }

    private static func name(_ state: ghostty_host_frame_e) -> String {
        switch state {
        case GHOSTTY_HOST_FRAME_NONE: "none"
        case GHOSTTY_HOST_FRAME_HIDDEN: "hidden"
        case GHOSTTY_HOST_FRAME_SHOWN: "shown"
        case GHOSTTY_HOST_FRAME_READY: "ready"
        case GHOSTTY_HOST_FRAME_PRESENTED: "presented"
        case GHOSTTY_HOST_FRAME_PENDING: "pending"
        case GHOSTTY_HOST_FRAME_HELD: "held"
        default: "other"
        }
    }
}
#endif
