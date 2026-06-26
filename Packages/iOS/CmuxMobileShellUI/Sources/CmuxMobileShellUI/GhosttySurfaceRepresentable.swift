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
///
/// The bottom dock (terminal grid / composer band / accessory toolbar / keyboard)
/// is owned entirely by the `GhosttySurfaceView` in one coordinate system. The
/// iMessage-style composer is a SwiftUI view, so it is hosted in a
/// `UIHostingController` and installed into the surface's composer band; this
/// representable is the only layer that can see both the terminal package and the
/// shell-UI composer, so it owns that bridge. The surface owns the band's position
/// and the grid reservation; the host reports the field's measured height back so a
/// field-grow pushes only the terminal up. There is no toolbar handoff and no second
/// layout system reaching into the surface's bottom math.
struct GhosttySurfaceRepresentable: UIViewRepresentable {
    let surfaceID: String
    let store: CMUXMobileShellStore
    let fontSize: Float32
    /// Whether the mounted surface should grab the keyboard when it attaches to
    /// a window. Driven by the host's autofocus-suppression state so chrome
    /// actions (create workspace/terminal, switch terminal) do not pop the
    /// software keyboard.
    var autoFocusOnWindowAttach: Bool = true
    /// Whether the iMessage-style composer is open. When it flips on, the
    /// coordinator mounts the SwiftUI compose field into the surface's composer
    /// band and pins first responder so the keyboard hands over in place; when it
    /// flips off, the field is unmounted and the band collapses to zero height.
    var isComposerActive: Bool = false

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
        #if DEBUG
        // Hand the surface the structured diagnostic log so the composer-dock
        // probes land in the blob the "Send to agent" feedback pane exports.
        // `nil` when no log is wired; every probe is then a no-op.
        view.diagnosticLog = store.diagnosticLog
        #endif
        // Stamp the shell-level id so id-scoped registry lookups (the
        // "View as Text" capture) resolve this exact terminal.
        view.hostSurfaceID = surfaceID
        context.coordinator.attach(surfaceView: view)
        // Mount the composer band immediately if the composer was already open when
        // this surface was (re)built (e.g. a terminal switch while composing), and
        // seed the surface's composerActive flag to match. SwiftUI does call
        // `updateUIView` right after `makeUIView`, but the compose button's intent
        // math reads this flag, so it must never depend on that ordering contract.
        view.setComposerActive(isComposerActive)
        context.coordinator.setComposerMounted(isComposerActive)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Bytes flow via the byte sink; the prop-driven mutations are the autofocus
        // suppression and the composer's open/closed state. `setComposerActive`
        // handles the first-responder handover that keeps the keyboard up; the
        // coordinator mounts/unmounts the hosted compose field into the surface's
        // composer band. This is a UIKit-internal mutation, not a sibling-observed
        // state write, so it is safe in `updateUIView`.
        guard let surfaceView = uiView as? GhosttySurfaceView else { return }
        surfaceView.autoFocusOnWindowAttach = autoFocusOnWindowAttach
        surfaceView.setComposerActive(isComposerActive)
        context.coordinator.setComposerMounted(isComposerActive)
        // A width change (rotation) is not a text change, so the field-content trigger
        // misses it. Re-measure the open composer here so the band height tracks the new
        // width's wrapping. No-op when closed or when the height is unchanged.
        context.coordinator.remeasureComposerForLayoutChange()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        (uiView as? GhosttySurfaceView)?.prepareForDismantle()
        coordinator.tearDownComposer()
        coordinator.detach()
    }

    final class Coordinator: NSObject, GhosttySurfaceViewDelegate {
        let surfaceID: String
        weak var store: CMUXMobileShellStore?
        weak var surfaceView: GhosttySurfaceView?
        private var outputTask: Task<Void, Never>?
        private var liveFontTask: Task<Void, Never>?
        /// Hosts the SwiftUI ``TerminalComposerView`` so it can be installed into the
        /// surface's composer band. Built lazily on first open and torn down on
        /// dismantle; mounted/unmounted by ``setComposerMounted(_:)``.
        private var composerController: UIHostingController<TerminalComposerView>?
        private var composerMounted = false
        /// Bumped on every mount/unmount transition so a deferred close completion
        /// can tell whether it is still the latest transition. Guards the
        /// close-then-quickly-reopen race: an interrupted close animation still runs
        /// its completion, which must not unmount a composer that was remounted in
        /// the meantime.
        private var composerMountGeneration = 0

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
            outputTask = Task { @MainActor [weak surfaceView, weak store] in
                guard let store else { return }
                for await chunk in store.terminalOutputStream(surfaceID: surfaceID) {
                    guard !Task.isCancelled else { return }
                    guard let surfaceView else { return }
                    await surfaceView.processOutputAndWait(chunk.data)
                    store.terminalOutputDidProcess(
                        surfaceID: surfaceID,
                        streamToken: chunk.streamToken
                    )
                    // Verify the applied grid against the producer's stamped hash
                    // and resync on divergence so a delta that silently missed a
                    // row self-corrects instead of staying blank. Throttled and
                    // dark-launch-gated inside the surface, so this is a no-op on
                    // the common path.
                    if await surfaceView.appliedGridDivergesFromExpected(
                        chunk.expectedGridHash,
                        surfaceID: surfaceID
                    ) {
                        store.requestTerminalRenderGridResync(surfaceID: surfaceID)
                    }
                }
            }
            // Drive Mac-pushed live font-size changes (`terminal.set_font`) into
            // the surface's shared zoom apply path. Runs for the surface's whole
            // mount, ending when the representable is dismantled.
            liveFontTask = Task { @MainActor [weak surfaceView, weak store] in
                guard let store else { return }
                for await points in store.terminalLiveFontStream(surfaceID: surfaceID) {
                    guard !Task.isCancelled else { return }
                    guard let surfaceView else { return }
                    surfaceView.setLiveFontSize(points)
                }
            }
        }

        func detach() {
            outputTask?.cancel()
            outputTask = nil
            liveFontTask?.cancel()
            liveFontTask = nil
        }

        // MARK: - Composer band hosting

        /// Mount or unmount the SwiftUI compose field into the surface's composer
        /// band so the surface owns its position and grid reservation. Idempotent.
        @MainActor
        func setComposerMounted(_ mounted: Bool) {
            guard mounted != composerMounted, let store, let surfaceView else { return }
            composerMounted = mounted
            composerMountGeneration &+= 1
            if mounted {
                let controller = composerController ?? makeComposerController(store: store)
                composerController = controller
                surfaceView.mountComposerView(controller.view)
                // The field opens at one line; report its initial height without
                // animation (the composer's open transition already animates), then
                // live grows/shrinks animate.
                reportComposerHeight(animated: false)
            } else {
                // Symmetric close: animate the band to 0 with the field STILL
                // mounted, on the keyboard curve, then unmount it in the completion.
                // Unmounting first left the band collapsing over empty space (a janky
                // close). Keep the surface reference for the deferred unmount.
                //
                // The completion is generation-guarded: UIKit runs animation
                // completions even when the animation is interrupted, so a
                // close-then-quick-reopen would otherwise unmount the freshly
                // remounted field and leave `composerMounted` true with no view.
                let generation = composerMountGeneration
                surfaceView.setComposerBandHeight(0, animated: true) { [weak self] in
                    guard let self,
                          self.composerMountGeneration == generation,
                          !self.composerMounted else { return }
                    self.surfaceView?.mountComposerView(nil)
                }
            }
        }

        /// Build the hosting controller for the compose field. The field asks for a
        /// re-measure (via ``reportComposerHeight(animated:)``) whenever its content
        /// changes; the coordinator measures the ideal height with `sizeThatFits` and
        /// sizes the surface band.
        @MainActor
        private func makeComposerController(store: CMUXMobileShellStore) -> UIHostingController<TerminalComposerView> {
            let view = TerminalComposerView(store: store, terminalID: surfaceID) { [weak self] in
                // Content changed (a line added/removed, or cleared after send): live
                // grows/shrinks animate. `setComposerBandHeight` is idempotent on
                // unchanged heights, so a no-op change is harmless.
                self?.reportComposerHeight(animated: true)
            }
            let controller = UIHostingController(rootView: view)
            // The field is pinned edge-to-edge in the band, so the band frame (not an
            // intrinsic size) drives the hosting view's height; the measured ideal
            // height flows separately through `sizeThatFits`. Clear background so the
            // terminal/glass shows through.
            controller.view.backgroundColor = .clear
            return controller
        }

        /// Measure the hosted compose field's ideal height and size the surface band.
        /// `sizeThatFits` returns the height the content wants independent of the band's
        /// current (pinned) frame, so it is not circular: the band height is set FROM
        /// this measurement, and the measurement does not depend on the band height.
        /// The proposed width is the surface width and the proposed height is unbounded
        /// so a multi-line field measures its full desired height (capped to 14 lines by
        /// the field's own `lineLimit`).
        @MainActor
        private func reportComposerHeight(animated: Bool) {
            guard let controller = composerController, let surfaceView else { return }
            let width = max(1, surfaceView.bounds.width)
            let target = CGSize(width: width, height: .greatestFiniteMagnitude)
            let fitting = controller.sizeThatFits(in: target)
            surfaceView.setComposerBandHeight(fitting.height, animated: animated)
        }

        /// Re-measure the open composer after a non-text layout change (rotation /
        /// width change). A no-op when the composer is closed; `setComposerBandHeight`
        /// is idempotent on an unchanged height. Animated so a rotation reflow is smooth.
        @MainActor
        func remeasureComposerForLayoutChange() {
            guard composerMounted else { return }
            reportComposerHeight(animated: true)
        }

        /// Tear the hosting controller down on dismantle so a removed surface does not
        /// leave a detached SwiftUI host alive.
        @MainActor
        func tearDownComposer() {
            surfaceView?.mountComposerView(nil)
            composerController = nil
            composerMounted = false
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
                surfaceView?.applyViewSize(cols: effective.columns, rows: effective.rows)
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

        func ghosttySurfaceViewDidRequestComposerToggle(_ surfaceView: GhosttySurfaceView) {
            // The composer button on the docked accessory bar was tapped AND the
            // surface resolved (from the dock state) that this is a genuine open/close
            // toggle. Flip the store flag; the terminal screen observes it and
            // presents/dismisses the iMessage-style composer. The reveal-and-focus
            // case routes through `...DidRequestComposerFocus` instead, so this never
            // closes a still-presented-but-suppressed composer.
            Task { @MainActor [weak store, surfaceID] in
                store?.toggleComposer(forTerminalID: surfaceID)
            }
        }

        func ghosttySurfaceViewDidRequestComposerFocus(_ surfaceView: GhosttySurfaceView) {
            // The surface needs the composer presented (if not already) and its field
            // re-focused, without dismissing it — the reveal-after-hide and
            // present-while-suppressed paths. Ensure-present + bump the focus token the
            // composer view observes, so the draft and its focus return together.
            Task { @MainActor [weak store, surfaceID] in
                store?.presentAndFocusComposer(forTerminalID: surfaceID)
            }
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
