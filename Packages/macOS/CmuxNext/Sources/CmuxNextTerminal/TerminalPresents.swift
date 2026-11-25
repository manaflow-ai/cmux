import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import GhosttyNextKit

/// Each frame Ghostty shows on one surface's layer, from Ghostty's present callback
/// (`ghostty_surface_set_present_callback`): its pixel size, why it changed (content or resize), the renderer's
/// present sequence and the host time. Ghostty calls it on the thread that sets the layer's contents: the GPU
/// completion thread after its own transaction committed (a frame at the shown size), the main thread otherwise (a
/// new size, the first frame, a display pass).
///
/// Every frame then tells the terminal's predictive echo engine (held confirmations retire with the frame that shows
/// the echo), the typing probe (``TypingLatencyProbe/Mark/contents``, only while it runs) and, in DEBUG and bench
/// builds, an armed `debug.new_terminal_trace` run. The pane check (``TerminalPaneFollowProbe``) and the blank check
/// after a reveal (``TerminalBlankWatch``) read ``last`` and ``count``. Owned by the surface's ``SurfaceBridge``, the
/// callback's userdata, which lives until `ghostty_surface_free` returns.
nonisolated final class TerminalPresents: Sendable {
    /// One frame Ghostty showed on the layer.
    struct Present: Sendable, Equatable {
        enum Reason: Sendable, Equatable {
            /// The same pixel size as the frame shown before it: output, an echo, a scroll, the cursor.
            case content
            /// Another pixel size than the frame shown before it, or the first frame.
            case resize
        }

        var widthPixels: Int
        var heightPixels: Int
        var reason: Reason
        /// The renderer's present sequence: larger is newer; 0 for a frame drawn on the main thread.
        var sequence: UInt64
        /// `mach_absolute_time()` just after the frame became the layer's contents.
        var hostTime: UInt64
    }

    private let prediction: TerminalEchoPrediction?
    /// The layer the frames go to (the typing probe's and the trace's source), set once its surface exists.
    private let layer = Mutex<ObjectIdentifier?>(nil)
    private let lastPresent = Mutex<Present?>(nil)
    private let presented = Atomic<UInt64>(0)

    init(prediction: TerminalEchoPrediction?) {
        self.prediction = prediction
    }

    /// The last frame Ghostty showed on the layer; nil before the first.
    var last: Present? { lastPresent.withLock { $0 } }

    /// Frames Ghostty showed on the layer so far.
    var count: UInt64 { presented.load(ordering: .relaxed) }

    /// Asks `surface` to report its frames here; `layer` is the surface view's layer, the source the typing probe and
    /// the trace name. `userdata` is the surface's bridge, which owns this feed and outlives `ghostty_surface_free`.
    @MainActor func install(on surface: ghostty_surface_t, layer: ObjectIdentifier?, userdata: UnsafeMutableRawPointer) {
        self.layer.withLock { $0 = layer }
        ghostty_surface_set_present_callback(surface, ghosttyPresent, userdata)
    }

    /// One frame reached the layer (Ghostty's present callback): any thread, never waits for another thread.
    func record(_ present: Present) {
        lastPresent.withLock { $0 = present }
        presented.add(1, ordering: .relaxed)
        prediction?.presentedFrame()
        let layer = self.layer.withLock { $0 }
        guard let layer else { return }
        if TypingLatencyProbe.isEnabled { TypingLatencyProbe.shared.mark(.contents, source: .object(layer)) }
        #if DEBUG || CMUX_BENCH_HOOKS
        if NewTerminalTrace.shared.isArmed { NewTerminalTrace.shared.contents(layer: layer) }
        #endif
    }
}

extension TerminalPresents.Present {
    /// Runs on the thread of Ghostty's present callback, so it is not on the main actor (the package default).
    nonisolated init(_ raw: ghostty_surface_present_s) {
        self.init(widthPixels: Int(raw.width_px), heightPixels: Int(raw.height_px),
                  reason: raw.reason == GHOSTTY_PRESENT_RESIZE ? .resize : .content,
                  sequence: raw.seq, hostTime: raw.host_time)
    }
}

/// `ghostty_surface_present_cb`: runs on the thread that set the layer's contents (the GPU completion thread or main).
nonisolated func ghosttyPresent(_ userdata: UnsafeMutableRawPointer?, _ present: UnsafePointer<ghostty_surface_present_s>) {
    guard let bridge = SurfaceBridge.from(userdata) else { return }
    bridge.presents.record(TerminalPresents.Present(present.pointee))
}
