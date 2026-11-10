#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign
import GhosttyNextKit
import IOSurface

extension TerminalSurfaceView {
    /// Adds `motionSample` to `debug.motion`'s trace samplers, once: a static `let` runs its initializer one time (the
    /// first surface view reads it).
    static let motionSamplerRegistration: Void = MotionDebug.registeredSamplers.append(motionSample)

    /// `debug.motion` `trace_*` sampler (which present path drew each terminal frame in a drag): per display frame, each
    /// shown terminal surface as `terminal`: `[x, y, width, height, shown width px, shown height px, frames, off-main
    /// presents, size presents, display passes, main draws, held frames, main presents]`.
    /// The rect is the surface layer in window points with a top-left origin (the committed model); `shown` is the
    /// IOSurface the layer shows (0 before the first frame); the counters are Ghostty's render counters, cumulative.
    /// It reads only while the trace records; nothing runs when it does not.
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
        let row: [Any] = [rounded(rect.minX), rounded(top), rounded(rect.width), rounded(rect.height),
                          shown?.width ?? 0, shown?.height ?? 0,
                          counters.frames, counters.host_off_main_presents, counters.host_size_presents,
                          counters.host_display_passes, counters.host_main_draws, counters.host_held_frames,
                          counters.host_main_presents]
        return ["terminal": [row]]
    }
}
#endif
