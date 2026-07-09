#if canImport(UIKit)
import CMUXMobileCore
import CmuxAgentChat
import CmuxMobileDiagnostics
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTerminal
import SwiftUI
import UIKit

/// SwiftUI wrapper that mounts a `GhosttySurfaceView` and routes terminal output
/// chunks into `ghostty_surface_process_output`. Primary-screen output can stay
/// at the phone's natural height, while alternate-screen render-grid replay can
/// pin the surface to the Mac's authoritative grid.
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
    /// The store's terminal-theme generation. The shell writes the synced theme
    /// into `TerminalThemeStore` directly (it does not link GhosttyKit), so this
    /// representable — which does — drives the live recolor: when the generation
    /// advances, it rebuilds the runtime config and refreshes the mounted
    /// surface's background/colors in place via `GhosttyRuntime.applyLiveThemeIfRunning()`.
    var themeGeneration: UInt64 = 0
    var artifactFilesEnabled: Bool = false
    var onArtifactFilesRequested: @MainActor () -> Void = {}
    var onArtifactPathTapped: @MainActor (_ path: String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            surfaceID: surfaceID,
            store: store,
            artifactFilesEnabled: artifactFilesEnabled,
            onArtifactFilesRequested: onArtifactFilesRequested,
            onArtifactPathTapped: onArtifactPathTapped
        )
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
            fallback.text = L10n.string(
                "mobile.terminal.rendererFailed",
                defaultValue: "Terminal renderer failed to start."
            )
            return fallback
        }
        let view = GhosttySurfaceView(
            runtime: runtime,
            delegate: context.coordinator,
            fontSize: fontSize
        )
        view.autoFocusOnWindowAttach = autoFocusOnWindowAttach
        view.artifactFilesEnabled = artifactFilesEnabled
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
        // The shared runtime is a process singleton; its config can carry a stale
        // theme from before this connect. A freshly built surface reads its local
        // background from the (current) theme store, but the renderer's default
        // colors come from the runtime config, so rebuild it to the current theme
        // when a theme has been applied. Records the generation so updateUIView
        // does not re-apply the same one.
        if themeGeneration > 0 {
            GhosttyRuntime.applyLiveThemeIfRunning()
        }
        context.coordinator.lastAppliedThemeGeneration = themeGeneration
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
        surfaceView.artifactFilesEnabled = artifactFilesEnabled
        context.coordinator.artifactFilesEnabled = artifactFilesEnabled
        context.coordinator.onArtifactFilesRequested = onArtifactFilesRequested
        context.coordinator.onArtifactPathTapped = onArtifactPathTapped
        surfaceView.setComposerActive(isComposerActive)
        context.coordinator.setComposerMounted(isComposerActive)
        // Live theme change: the shell bumped the generation after writing the new
        // theme into TerminalThemeStore. Rebuild the runtime config and recolor
        // the mounted surface(s) in place so the background follows the new theme
        // even when the `.id()` remount reused this same view.
        if themeGeneration != context.coordinator.lastAppliedThemeGeneration {
            context.coordinator.lastAppliedThemeGeneration = themeGeneration
            GhosttyRuntime.applyLiveThemeIfRunning()
        }
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
        var artifactFilesEnabled: Bool
        var onArtifactFilesRequested: @MainActor () -> Void
        var onArtifactPathTapped: @MainActor (_ path: String) -> Void
        private var outputTask: Task<Void, Never>?
        private var liveFontTask: Task<Void, Never>?
        /// Hosts the SwiftUI ``TerminalComposerView`` so it can be installed into the
        /// surface's composer band. Built lazily on first open and torn down on
        /// dismantle; mounted/unmounted by ``setComposerMounted(_:)``.
        private var composerController: UIHostingController<TerminalComposerView>?
        private var composerMounted = false
        /// The theme generation already pushed to the live runtime, so a repeated
        /// `updateUIView` for the same generation does not rebuild the config again.
        var lastAppliedThemeGeneration: UInt64 = 0
        private var activeViewportPolicy: MobileTerminalOutputViewportPolicy = .natural
        /// Serializes the natural-grid viewport reports and their echoes. One
        /// detached Task per report (the previous shape) let Task scheduling
        /// scramble the send order AND let the echo of an old keyboard-up
        /// report resolve after the newer keyboard-down echo, permanently
        /// re-pinning the phone to the stale smaller grid (empty space above
        /// the terminal). Built on attach, torn down on detach.
        private var viewportReportScheduler: TerminalViewportReportScheduler?
        /// Bumped on every mount/unmount transition so a deferred close completion
        /// can tell whether it is still the latest transition. Guards the
        /// close-then-quickly-reopen race: an interrupted close animation still runs
        /// its completion, which must not unmount a composer that was remounted in
        /// the meantime.
        private var composerMountGeneration = 0

        init(
            surfaceID: String,
            store: CMUXMobileShellStore,
            artifactFilesEnabled: Bool,
            onArtifactFilesRequested: @escaping @MainActor () -> Void,
            onArtifactPathTapped: @escaping @MainActor (_ path: String) -> Void
        ) {
            self.surfaceID = surfaceID
            self.store = store
            self.artifactFilesEnabled = artifactFilesEnabled
            self.onArtifactFilesRequested = onArtifactFilesRequested
            self.onArtifactPathTapped = onArtifactPathTapped
            super.init()
        }

        func attach(surfaceView: GhosttySurfaceView) {
            self.surfaceView = surfaceView
            surfaceView.artifactFilesEnabled = artifactFilesEnabled
            guard let store else { return }
            let surfaceID = surfaceID
            viewportReportScheduler = TerminalViewportReportScheduler(
                send: { [weak self] report in
                    guard let self, let store = self.store else { return nil }
                    return await store.updateTerminalViewport(
                        surfaceID: self.surfaceID,
                        columns: report.columns,
                        rows: report.rows
                    )
                },
                apply: { [weak self, weak surfaceView] report, effectiveGrid in
                    guard let self, let surfaceView else { return }
                    guard let effectiveGrid else {
                        // No effective grid came back (RPC timed out or
                        // returned nil). Left unhandled, the render stays
                        // pinned to the prior effective grid and looks like a
                        // frozen / letterboxed terminal even though the main
                        // thread is fine. Re-arm the report so a transient
                        // drop self-heals (bounded inside the surface).
                        MobileDebugLog.anchormux(
                            "zoom.viewport.noEffective grid=\(report.columns)x\(report.rows)"
                        )
                        surfaceView.retryViewportReport()
                        return
                    }
                    surfaceView.markViewportReportConfirmed()
                    if case .remoteGrid = self.activeViewportPolicy {
                        surfaceView.applyConfirmedViewSize(
                            cols: effectiveGrid.columns,
                            rows: effectiveGrid.rows,
                            reportID: report.id
                        )
                    }
                }
            )
            // Drive every output chunk into the libghostty surface. Ending this
            // task terminates the stream, which unregisters the surface and
            // clears its viewport pin on the Mac (see `terminalOutputStream`).
            outputTask = Task { @MainActor [weak self, weak surfaceView, weak store] in
                guard let store else { return }
                for await chunk in store.terminalOutputStream(surfaceID: surfaceID) {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    guard let surfaceView else { return }
                    switch chunk.viewportPolicy {
                    case .natural:
                        self.activeViewportPolicy = .natural
                        if chunk.data.isEmpty {
                            surfaceView.useNaturalViewSize()
                        } else {
                            let applied = await surfaceView.useNaturalViewSizeAndWait()
                            guard applied else {
                                store.terminalOutputDidReset(
                                    surfaceID: surfaceID,
                                    streamToken: chunk.streamToken
                                )
                                continue
                            }
                        }
                    case .remoteGrid(let columns, let rows):
                        self.activeViewportPolicy = .remoteGrid(columns: columns, rows: rows)
                        if chunk.data.isEmpty {
                            surfaceView.applyViewSize(cols: columns, rows: rows)
                        } else {
                            let applied = await surfaceView.applyViewSizeAndWait(cols: columns, rows: rows)
                            guard applied else {
                                store.terminalOutputDidReset(
                                    surfaceID: surfaceID,
                                    streamToken: chunk.streamToken
                                )
                                continue
                            }
                        }
                    case nil:
                        break
                    }
                    if !chunk.data.isEmpty {
                        let applied = await surfaceView.processOutputAndWait(chunk.data)
                        guard applied else {
                            store.terminalOutputDidReset(
                                surfaceID: surfaceID,
                                streamToken: chunk.streamToken
                            )
                            continue
                        }
                    }
                    store.terminalOutputDidProcess(
                        surfaceID: surfaceID,
                        streamToken: chunk.streamToken
                    )
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
            viewportReportScheduler?.cancel()
            viewportReportScheduler = nil
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
        ///
        /// `requestHeightRemeasure` fires the instant the field's content changes — a
        /// `.onChange(of:)` action, or the post-send clear — which is BEFORE SwiftUI has
        /// committed that change into the hosted controller's view graph. Measuring a
        /// `UIHostingController` synchronously at that point captures the PRE-change
        /// (tall) ideal height, so after a send the band stays reserved tall and the
        /// empty field renders as a tall box that never collapses. It is worst for an
        /// image-only send: clearing the text fires no `.onChange(of: terminalInputText)`
        /// (it was already empty), so the stale measurement is never corrected by a
        /// follow-up. Flush the host's pending SwiftUI update into a concrete layout pass
        /// BEFORE calling `sizeThatFits` — mirroring the `setNeedsLayout()`/
        /// `layoutIfNeeded()` the GUI chat composer relies on to keep its hosted-field
        /// measurement current — so the measurement reflects the new (e.g. collapsed
        /// one-line) content. `sizeThatFits` re-proposes the surface width itself, so the
        /// flush only needs to apply the pending content change, not fix the width.
        @MainActor
        private func reportComposerHeight(animated: Bool) {
            guard let controller = composerController, let surfaceView else { return }
            // The hosting controller is mounted before any remeasure, so its view is
            // loaded; annotate to force-unwrap the `UIView!` rather than infer `UIView?`.
            let hostView: UIView = controller.view
            hostView.setNeedsLayout()
            hostView.layoutIfNeeded()
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

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {
            // Report our natural grid to the Mac. The output stream decides
            // whether the phone should keep that natural grid (primary screen)
            // or pin to the Mac grid (alternate-screen render-grid replay).
            // The scheduler serializes the RPCs (send order = report order,
            // so the PTY settles on the NEWEST grid) and drops echoes whose
            // report was superseded while in flight; the surface additionally
            // rejects any echo whose reportID is no longer the newest.
            guard size.columns > 0, size.rows > 0 else { return }
            viewportReportScheduler?.submit(
                .init(id: reportID, columns: size.columns, rows: size.rows)
            )
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
                if self.artifactFilesEnabled,
                   let text = await surfaceView.visibleTextForArtifactHitTesting() {
                    if let path = TerminalArtifactTapHitTester().path(in: text, col: col, row: row) {
                        self.onArtifactPathTapped(path)
                        return
                    }
                }
                await self.store?.clickTerminal(surfaceID: self.surfaceID, col: col, row: row)
            }
        }

        func ghosttySurfaceViewDidRequestArtifactFiles(_ surfaceView: GhosttySurfaceView) {
            Task { @MainActor [weak self] in
                self?.onArtifactFilesRequested()
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

        func ghosttySurfaceViewDidResetRenderPipeline(_ surfaceView: GhosttySurfaceView) {
            Task { @MainActor [weak self, weak store, surfaceID] in
                guard let self, self.surfaceView === surfaceView else { return }
                store?.terminalOutputNeedsReplay(surfaceID: surfaceID)
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

private struct TerminalArtifactTapHitTester {
    func path(in text: String, col: Int, row: Int) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard row >= 0, row < lines.count else { return nil }
        let line = lines[row]
        for token in tokenRanges(in: line) {
            guard col >= token.startColumn, col < token.endColumn else { continue }
            return token.path
        }
        return nil
    }

    private func tokenRanges(in line: String) -> [(path: String, startColumn: Int, endColumn: Int)] {
        var result: [(path: String, startColumn: Int, endColumn: Int)] = []
        var index = line.startIndex
        while index < line.endIndex {
            while index < line.endIndex, line[index].isWhitespace {
                index = line.index(after: index)
            }
            guard index < line.endIndex else { break }
            let tokenStart = index
            while index < line.endIndex, !line[index].isWhitespace {
                index = line.index(after: index)
            }
            let raw = String(line[tokenStart..<index])
            guard let path = TerminalArtifactPathDetector().tokens(in: raw).first?.path else {
                continue
            }
            let leadingTrim = raw.count - raw.drop(while: { Self.leadingTrimCharacters.contains($0) }).count
            let start = line.distance(from: line.startIndex, to: tokenStart) + leadingTrim
            result.append((path: path, startColumn: start, endColumn: start + path.count))
        }
        return result
    }

    private static let leadingTrimCharacters: Set<Character> = ["\"", "'", "`", "(", "[", "{", "<"]
}
#endif
