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
    /// display passes, main draws, late presents, owned, presenter, host frame, id, size asks]`.
    /// The rect is what shows of the surface layer (cut by each ancestor that clips: its pane's clip) in window points
    /// with a top-left origin (the committed model); a surface none of which shows has no row; `shown` is the
    /// IOSurface the layer shows (0 before the first frame); the counters are Ghostty's render counters, cumulative
    /// (a frame that went through main is one of `frames` that is neither an off-main nor a fresh present);
    /// `owned` is 1 once its window's commit owns its frame (every made surface, cmux-ad m19); `presenter` is
    /// ``TerminalFramePresenter/debugState(of:)`` (request, watch, commit or -); `host frame` is what
    /// `ghostty_surface_host_frame` answers now without presenting (owned only, else "-"); `id` names the surface for
    /// the trace's life (a terminal that moves to another pane is one mover); `size asks` are the sizes asked of it or given
    /// to it since the last sample, each with its calls (``noteSizeAskForTrace(_:_:)``). It reads only while the trace
    /// records; nothing runs when it does not.
    static func motionSample(_ view: NSView) -> [String: [Any]]? {
        guard let surfaceView = view as? TerminalSurfaceView else { return nil }
        guard let window = surfaceView.window, let surface = surfaceView.surface, !surfaceView.isHiddenOrHasHiddenAncestor,
              let layer = surfaceView.layer, let root = window.contentView?.layer else { return [:] }
        // What shows of it: its layer cut by every ancestor that clips (its pane's clip: a pane a change brought in
        // has no size until the frame that shows the change, so nothing of a terminal moved into it shows). Nothing
        // shows: no row.
        var rect = layer.convert(layer.bounds, to: root)
        var ancestor = surfaceView.superview
        while let view = ancestor, let clip = view.layer, clip !== root {
            if view.clipsToBounds || clip.masksToBounds { rect = rect.intersection(clip.convert(clip.bounds, to: root)) }
            ancestor = view.superview
        }
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return [:] }
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
                          String(UInt(bitPattern: ObjectIdentifier(surfaceView).hashValue), radix: 16),
                          surfaceView.frameOwnership.debugSizeAsks]
        surfaceView.frameOwnership.debugSizeAsks = []
        return ["terminal": [row]]
    }

    /// Notes a size asked of this view or given to it while a trace runs (`kind`: `place`, `frame` set outside a landing,
    /// `land`), with the calls that made it; the next sample's row carries the notes since the last one.
    func noteSizeAskForTrace(_ kind: String, _ size: CGSize) {
        let stack = Thread.callStackSymbols.dropFirst(2).prefix(16).map { line in
            line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).prefix(1).joined()
        }.joined(separator: "<")
        let note = "\(kind) \(Int(size.width))x\(Int(size.height)) @\(Int(CACurrentMediaTime() * 1000)): \(stack)"
        frameOwnership.debugSizeAsks = Array((frameOwnership.debugSizeAsks + [note]).suffix(8))
    }

    private static func name(_ state: ghostty_host_frame_e) -> String {
        switch state {
        case GHOSTTY_HOST_FRAME_NONE: "none"
        case GHOSTTY_HOST_FRAME_HIDDEN: "hidden"
        case GHOSTTY_HOST_FRAME_SHOWN: "shown"
        case GHOSTTY_HOST_FRAME_READY: "ready"
        case GHOSTTY_HOST_FRAME_READY_PROGRAM: "ready_program"
        case GHOSTTY_HOST_FRAME_PRESENTED: "presented"
        case GHOSTTY_HOST_FRAME_PENDING: "pending"
        case GHOSTTY_HOST_FRAME_HELD: "held"
        default: "other"
        }
    }
}
#endif
