#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileTerminalKit
import GhosttyKit
import OSLog
import UIKit

// MARK: - Ghostty Callbacks & Daemon Output
extension GhosttySurfaceView {
    func scrollInitialOutputToBottomIfNeeded() {
        guard shouldScrollInitialOutputToBottom, let surface else { return }
        shouldScrollInitialOutputToBottom = false
        // `ghostty_surface_binding_action` takes the same internal surface lock
        // as `process_output`/`render_now`. This runs on the MAIN thread (inside
        // the `processOutput` completion hop), so calling it inline would contend
        // that lock against the off-main renderer/IO during a render storm and
        // wedge main on libghostty's futex. Dispatch it on the serial surface
        // queue like the absolute `set_font_size` push (see
        // `applyPendingFontSizeIfNeeded`); enqueuing after any pending
        // `process_output` also preserves ordering. The return was already
        // discarded.
        let action = "scroll_to_bottom"
        Self.outputQueue.async {
            action.withCString { pointer in
                _ = ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
            }
        }
    }

    static func forwardDaemonOutputBytes(_ data: Data) -> Data {
        // The daemon owns terminal byte semantics. iOS must feed Ghostty the
        // exact VT stream it received so desktop and mobile render the same
        // session history and prompt state.
        data
    }

    /// The final DECTCEM cursor-visibility state in `data`, or nil if the chunk
    /// contains no cursor show/hide. Scans for the exact sequences the
    /// render-grid producer emits: `ESC [ ? 2 5 h` (show) / `ESC [ ? 2 5 l`
    /// (hide). The last occurrence wins, so a delta that toggles ends on the
    /// applied state.
    nonisolated static func lastCursorVisibility(in data: Data) -> Bool? {
        TerminalDECTCEMCursorScanner.lastVisibility(in: data)
    }

    func handleOutboundBytes(_ bytes: Data) {
        // The mirror is display-only, so any bytes its libghostty writes toward a
        // PTY are spurious: the Mac is the real terminal and already produces
        // them. The clearest case is focus reporting — `set_focus` on
        // background/foreground, with mode 1004 restored from the Mac, emits
        // `ESC[O`/`ESC[I`, and forwarding those as input made the Mac type a
        // literal "[O[I". DA/cursor-query responses to bytes in the render-grid
        // stream are the same: the Mac already answered them. Real user input
        // flows through `inputProxy` (`didProduceInput`), not here, so dropping
        // these is safe.
        #if DEBUG
        TerminalInputDebugLog.log("surface.outboundDropped data=\(TerminalInputDebugLog.dataSummary(bytes))")
        #endif
    }

    @MainActor
    static func focusInput(for surface: ghostty_surface_t) {
        view(for: surface)?.focusInput()
    }

    @MainActor
    static func setTitle(_ title: String, for surface: ghostty_surface_t) {
        view(for: surface)?.surfaceTitle = title
    }

    @MainActor
    static func ringBell(for surface: ghostty_surface_t) {
        view(for: surface)?.handleBell()
    }

    @MainActor
    static func title(for surface: ghostty_surface_t) -> String? {
        view(for: surface)?.surfaceTitle
    }

    @MainActor
    static func drawVisibleSurfacesForWakeup() {
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
        for view in registeredSurfaceViews.values.compactMap(\.value) {
            view.drawForWakeup()
        }
    }

    /// "What the user sees": the visible viewport text of every on-screen
    /// terminal surface, for the DEV "Copy Debug Logs" action so a bug report
    /// pairs the on-screen content with the debug log. Reads the VIEWPORT
    /// (visible grid only, not scrollback) via libghostty.
    public static func visibleTerminalSnapshot() -> String {
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
        // Collect the main-actor state + surface pointers first, then read the
        // viewport text on the serial output queue. `ghostty_surface_read_text`
        // takes the same surface lock as `process_output` (which runs off-main);
        // reading it on the MAIN thread here contends that lock during a render
        // storm and stalls the present — tapping Copy Debug Logs would itself
        // blank the terminal. The output queue is never concurrent with
        // `process_output`, so the read can't wedge. No `main.sync` runs on that
        // queue, so this `.sync` cannot deadlock.
        var pending: [VisibleSnapshotRequest] = []
        for view in registeredSurfaceViews.values.compactMap(\.value) {
            guard view.window != nil, !view.isHidden, view.alpha > 0.01,
                  let surface = view.surface else { continue }
            let grid = view.effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "?"
            pending.append(VisibleSnapshotRequest(grid: grid, font: Int(view.liveFontSize), surface: surface))
        }
        if pending.isEmpty {
            return "===== visible terminal: (no on-screen surface) ====="
        }
        // Read on the output queue, but bound the wait. If a render wedge has the
        // queue stuck mid-`process_output`, a plain `.sync` here would freeze the
        // whole app exactly when the user taps Copy Debug Logs to capture that
        // bug. Time out and ship the logs without the snapshot instead.
        let holder = VisibleSnapshotHolder()
        // This synchronous DEV-only "Copy Debug Logs" path reads the viewport off
        // the serial output queue and must give up after a deadline if a render
        // wedge holds it; an actor/await cannot express the bounded synchronous
        // wait the synchronous caller needs.
        // carve-out justification: one-shot cross-queue completion signal with a
        // bounded wait, not a lock guarding shared state.
        let done = DispatchSemaphore(value: 0)
        outputQueue.async {
            var built: [String] = []
            for item in pending {
                let text = surfaceText(item.surface, pointTag: GHOSTTY_POINT_VIEWPORT) ?? "(unavailable)"
                built.append(
                    "===== visible terminal · grid=\(item.grid) · font=\(item.font) =====\n"
                    + text
                )
            }
            holder.sections = built
            done.signal()
        }
        if done.wait(timeout: .now() + 0.6) == .timedOut {
            return "===== visible terminal: (snapshot skipped — render busy) ====="
        }
        return holder.sections.joined(separator: "\n\n")
    }

    private func handleBell() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        NotificationCenter.default.post(
            name: .ghosttySurfaceDidRingBell,
            object: self
        )
    }
}

#endif
