#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileShell
import CmuxMobileTerminal
import SwiftUI
import UIKit

/// SwiftUI wrapper that mounts a `GhosttySurfaceView` and routes the
/// matching surface's PTY bytes (received via `terminal.bytes` events)
/// into `ghostty_surface_process_output`. The result is that the iPhone
/// runs the same libghostty terminal core + Metal renderer as the Mac,
/// fed by the Mac's own read thread byte-for-byte. No Swift VT parser,
/// no snapshot rehydration, no cell-by-cell SwiftUI tree.
struct GhosttySurfaceRepresentable: UIViewRepresentable {
    let surfaceID: String
    let store: CMUXMobileShellStore
    let fontSize: Float32
    /// Whether the mounted surface should grab the keyboard when it attaches to
    /// a window. Driven by the host's autofocus-suppression state so chrome
    /// actions (create workspace/terminal, switch terminal) do not pop the
    /// software keyboard.
    var autoFocusOnWindowAttach: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(surfaceID: surfaceID, store: store)
    }

    func makeUIView(context: Context) -> UIView {
        let runtime: GhosttyRuntime
        do {
            runtime = try GhosttyRuntime.shared()
        } catch {
            let fallback = UILabel()
            fallback.numberOfLines = 0
            fallback.textColor = .white
            fallback.backgroundColor = UIColor(red: 0x27/255.0, green: 0x28/255.0, blue: 0x22/255.0, alpha: 1)
            fallback.text = "Ghostty runtime failed to initialise:\n\(error.localizedDescription)"
            return fallback
        }
        let view = GhosttySurfaceView(
            runtime: runtime,
            delegate: context.coordinator,
            fontSize: fontSize
        )
        view.autoFocusOnWindowAttach = autoFocusOnWindowAttach
        context.coordinator.attach(surfaceView: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? GhosttySurfaceView)?.autoFocusOnWindowAttach = autoFocusOnWindowAttach
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        (uiView as? GhosttySurfaceView)?.prepareForDismantle()
        coordinator.detach()
    }

    final class Coordinator: NSObject, GhosttySurfaceViewDelegate {
        let surfaceID: String
        weak var store: CMUXMobileShellStore?
        weak var surfaceView: GhosttySurfaceView?
        private var outputTask: Task<Void, Never>?

        init(surfaceID: String, store: CMUXMobileShellStore) {
            self.surfaceID = surfaceID
            self.store = store
            super.init()
        }

        func attach(surfaceView: GhosttySurfaceView) {
            self.surfaceView = surfaceView
            guard let store else { return }
            let surfaceID = surfaceID
            // Drive every output chunk into the libghostty surface. Ending this
            // task terminates the stream, which unregisters the surface and
            // clears its viewport pin on the Mac (see `terminalOutputStream`).
            outputTask = Task { @MainActor [weak surfaceView] in
                for await chunk in store.terminalOutputStream(surfaceID: surfaceID) {
                    guard !Task.isCancelled else { return }
                    // Pin the authoritative Mac grid carried by this frame BEFORE
                    // applying its bytes (immediate: the resize lands on the
                    // serial output queue ahead of these bytes, so geometry and
                    // content stay atomic and the surface converges on attach and
                    // on any Mac-side resize without a phone-initiated round-trip).
                    // A grid-bearing chunk older than the surface's merged
                    // high-water mark is stale: its bytes would repaint stale
                    // content at the newer grid, so drop them. `nil` grid
                    // (raw-byte fallback) leaves the pin untouched and applies.
                    if let grid = chunk.grid {
                        let stale = surfaceView?.applyAuthoritativeGrid(
                            grid,
                            immediate: true
                        ) ?? false
                        if stale { continue }
                    }
                    surfaceView?.processOutput(chunk.bytes)
                }
            }
        }

        func detach() {
            outputTask?.cancel()
            outputTask = nil
        }

        // MARK: - GhosttySurfaceViewDelegate

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {
            // Bytes the iPhone wants to send TO the PTY (typing, paste,
            // mouse reports). Forward to the Mac sync server which
            // writes them into the Mac's libghostty surface, which in
            // turn writes them down the PTY.
            Task { @MainActor [weak store] in
                await store?.submitTerminalRawInput(data, surfaceID: self.surfaceID)
            }
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didPasteImage data: Data, format: String) {
            // An image the user pasted on the phone. Upload it to the Mac, which
            // writes a temp file and injects its path into the terminal so the
            // running TUI (e.g. Claude Code) attaches it.
            Task { @MainActor [weak store] in
                await store?.submitTerminalPasteImage(data, format: format)
            }
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize) {
            // Report our natural grid to the Mac and pin our render to the
            // effective grid it returns (the smallest across every attached
            // device, capped to the Mac pane). This is the tmux-style shared
            // resize: the smallest viewport wins and each device letterboxes
            // its render to match, drawing a border around the live area.
            guard size.columns > 0, size.rows > 0 else { return }
            Task { @MainActor [weak self, weak surfaceView] in
                guard let self, let store = self.store else { return }
                guard let effective = await store.updateTerminalViewport(
                    surfaceID: self.surfaceID,
                    columns: size.columns,
                    rows: size.rows
                ) else {
                    // No effective grid came back (RPC timed out or returned
                    // nil). Left unhandled, the render stays pinned to the prior
                    // effective grid and looks like a frozen / letterboxed
                    // terminal even though the main thread is fine. Re-arm the
                    // report so a transient drop self-heals (bounded inside the
                    // surface). Logged so the dogfood log still distinguishes
                    // this from a true main-thread wedge.
                    MobileDebugLog.anchormux("zoom.viewport.noEffective grid=\(size.columns)x\(size.rows)")
                    surfaceView?.retryViewportReport()
                    return
                }
                // The viewport reply is the only acknowledgement of a phone-side
                // resize the Mac does not push a render frame for (rotation,
                // keyboard show/hide, zoom while the Mac pane is occluded). Route
                // it through the SAME authoritative-grid path as the frame
                // stream, carrying the generation, so the merged decision
                // converges the pin without a stale reply ever rewinding a newer
                // frame. No bytes follow this reply, so apply it deferred
                // (immediate: false) to keep the fast-zoom/keyboard resize
                // coalescing instead of an immediate per-reply set_size storm.
                surfaceView?.confirmViewportReport()
                surfaceView?.applyAuthoritativeGrid(effective, immediate: false)
            }
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didScrollLines lines: Double, atCol col: Int, row: Int) {
            // Forward to the Mac's real surface; libghostty scrolls scrollback
            // (normal screen) or sends mouse-wheel to the program (alt screen).
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.store?.scrollTerminal(surfaceID: self.surfaceID, lines: lines, col: col, row: row)
            }
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didTapAtCol col: Int, row: Int) {
            // Forward to the Mac's real surface as a left click; libghostty
            // reports it to a TUI with mouse mode, or no-ops on a normal screen.
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.store?.clickTerminal(surfaceID: self.surfaceID, col: col, row: row)
            }
        }

        func ghosttySurfaceViewDidRequestToolbarSettings(_ surfaceView: GhosttySurfaceView) {
            // The "customize" button on the keyboard toolbar. The editor view
            // lives in this UI package, so present it here (the terminal package
            // that owns the bar can't reach up to it) from the surface's owning
            // view controller.
            guard let presenter = presentingController(for: surfaceView) else { return }
            let editor = UIHostingController(rootView: TerminalShortcutsSettingsView())
            presenter.present(editor, animated: true)
        }

        /// Walk up from `view` to the nearest owning `UIViewController`, then to
        /// its top-most presented controller, so a sheet presents above whatever
        /// is already on screen.
        @MainActor
        private func presentingController(for view: UIView) -> UIViewController? {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController {
                    var top = controller
                    while let presented = top.presentedViewController {
                        top = presented
                    }
                    return top
                }
                responder = current.next
            }
            return view.window?.rootViewController
        }
    }
}
#endif
