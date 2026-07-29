#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTerminal
import SwiftUI
import UIKit

/// Mounts a `GhosttySurfaceView`, routes terminal output, and bridges the SwiftUI
/// composer into the surface-owned bottom dock. Primary-screen output uses the
/// phone's natural height; alternate-screen replay can pin to the Mac's grid.
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
    /// Theme for this exact Mac terminal surface.
    var terminalTheme: TerminalTheme
    /// Raw Mac Ghostty defaults installed into the local mirror surface.
    var terminalConfigTheme: TerminalTheme
    /// The store's raw config generation. This drives a surface-local
    /// Ghostty config update without remounting or changing another scene.
    var configThemeGeneration: UInt64 = 0
    var composerSubmitAction: (@MainActor () async -> Void)? = nil
    var onComposerChromeHeightChange: ((CGFloat) -> Void)? = nil
    var onBottomScrollEdgeElementContainersChange: (@MainActor ([UIView]) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            surfaceID: surfaceID,
            store: store,
            composerSubmitAction: composerSubmitAction,
            onComposerChromeHeightChange: onComposerChromeHeightChange,
            onBottomScrollEdgeElementContainersChange: onBottomScrollEdgeElementContainersChange
        )
    }

    func makeUIView(context: Context) -> UIView {
        let runtime: GhosttyRuntime
        do {
            runtime = try GhosttyRuntime.shared()
        } catch {
            let fallback = UILabel()
            fallback.numberOfLines = 0
            fallback.textColor = terminalTheme.terminalForegroundUIColor
            fallback.backgroundColor = terminalTheme.terminalBackgroundUIColor
            fallback.text = L10n.string(
                "mobile.terminal.rendererFailed",
                defaultValue: "Terminal renderer failed to start."
            )
            return fallback
        }
        let view = GhosttySurfaceView(
            runtime: runtime,
            delegate: context.coordinator,
            fontSize: fontSize,
            terminalTheme: terminalTheme,
            terminalConfigTheme: terminalConfigTheme
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
        view.seedThemeParityPreviewIfRequested()
        // Mount the composer band immediately if the composer was already open when
        // this surface was (re)built (e.g. a terminal switch while composing), and
        // seed the surface's composerActive flag to match. SwiftUI does call
        // `updateUIView` right after `makeUIView`, but the compose button's intent
        // math reads this flag, so it must never depend on that ordering contract.
        view.setComposerActive(isComposerActive)
        context.coordinator.setComposerMounted(isComposerActive)
        context.coordinator.themeApplicationScheduler.seed(generation: configThemeGeneration)
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
        context.coordinator.updateComposerRouting(
            submitAction: composerSubmitAction,
            chromeHeightChange: onComposerChromeHeightChange,
            edgeElementContainersChange: onBottomScrollEdgeElementContainersChange
        )
        surfaceView.autoFocusOnWindowAttach = autoFocusOnWindowAttach
        surfaceView.terminalTheme = terminalTheme
        surfaceView.terminalConfigTheme = terminalConfigTheme
        surfaceView.setComposerActive(isComposerActive)
        context.coordinator.setComposerMounted(isComposerActive)
        context.coordinator.scheduleTheme(terminalConfigTheme, generation: configThemeGeneration)
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
        var outputStartContinuation: AsyncStream<Void>.Continuation?
        var preparedViewportReportsByReportID: [UInt64: MobileTerminalViewportPreparation] = [:]
        private var liveFontTask: Task<Void, Never>?
        let themeApplicationScheduler = TerminalThemeApplicationScheduler()
        /// Hosts the SwiftUI ``TerminalComposerView`` so it can be installed into the
        /// surface's composer band. Built lazily on first open and torn down on
        /// dismantle; mounted/unmounted by ``setComposerMounted(_:)``.
        var composerController: UIHostingController<TerminalComposerView>?
        let composerSubmitRouter: TerminalComposerSubmitRouter
        var onComposerChromeHeightChange: ((CGFloat) -> Void)?
        var onBottomScrollEdgeElementContainersChange: (@MainActor ([UIView]) -> Void)?
        var composerMounted = false
        private var activeViewportPolicy: MobileTerminalOutputViewportPolicy = .natural
        private let verifiedReplayState = VerifiedTerminalReplayStateMachine()
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
        var composerMountGeneration = 0

        init(
            surfaceID: String,
            store: CMUXMobileShellStore,
            composerSubmitAction: (@MainActor () async -> Void)?,
            onComposerChromeHeightChange: ((CGFloat) -> Void)?,
            onBottomScrollEdgeElementContainersChange: (@MainActor ([UIView]) -> Void)?
        ) {
            self.surfaceID = surfaceID
            self.store = store
            self.composerSubmitRouter = TerminalComposerSubmitRouter(action: composerSubmitAction)
            self.onComposerChromeHeightChange = onComposerChromeHeightChange
            self.onBottomScrollEdgeElementContainersChange = onBottomScrollEdgeElementContainersChange
            super.init()
        }

        func updateComposerRouting(
            submitAction: (@MainActor () async -> Void)?,
            chromeHeightChange: ((CGFloat) -> Void)?,
            edgeElementContainersChange: (@MainActor ([UIView]) -> Void)?
        ) {
            composerSubmitRouter.action = submitAction
            onComposerChromeHeightChange = chromeHeightChange
            onBottomScrollEdgeElementContainersChange = edgeElementContainersChange
            if let surfaceView {
                edgeElementContainersChange?(surfaceView.bottomScrollEdgeElementContainers)
            }
        }

        func attach(surfaceView: GhosttySurfaceView) {
            self.surfaceView = surfaceView
            onBottomScrollEdgeElementContainersChange?(
                surfaceView.bottomScrollEdgeElementContainers
            )
            guard let store else { return }
            let surfaceID = surfaceID
            let outputStartSignal = AsyncStream<Void> { [weak self] continuation in
                self?.outputStartContinuation = continuation
            }
            viewportReportScheduler = TerminalViewportReportScheduler(
                send: { [weak self] report in
                    guard let self, let store = self.store else { return nil }
                    if let preparation = self.preparedViewportReportsByReportID.removeValue(
                        forKey: report.id
                    ) {
                        return await store.updatePreparedTerminalViewport(preparation)
                    }
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
                    surfaceView.markViewportReportConfirmed(reportID: report.id)
                    if let renderEpoch = effectiveGrid.renderEpoch,
                       let renderRevisionFloor = effectiveGrid.renderRevisionFloor {
                        self.verifiedReplayState.acknowledgeViewport(
                            renderEpoch: renderEpoch,
                            renderRevisionFloor: renderRevisionFloor
                        )
                    }
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
                for await _ in outputStartSignal { break }
                guard !Task.isCancelled else { return }
                guard let store else { return }
                for await chunk in store.terminalOutputStream(surfaceID: surfaceID) {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    guard let surfaceView else { return }
                    switch terminalOutputApplicationPath(
                        for: chunk,
                        expectedSurfaceID: surfaceID
                    ) {
                    case .verifiedReplay:
                        guard let frame = chunk.sourceRenderGridFrame else { return }
                        await self.applyVerifiedRenderGrid(
                            frame,
                            chunk: chunk,
                            surfaceView: surfaceView,
                            store: store
                        )
                        continue
                    case .rejectUnverified:
                        let transactionID = self.verifiedReplayState.rejectUnverifiedOutput()
                        _ = await surfaceView.freezeVerifiedReplayPresentation(
                            transactionID: transactionID
                        )
                        guard !Task.isCancelled else { return }
                        store.terminalOutputDidReset(
                            surfaceID: surfaceID,
                            streamToken: chunk.streamToken
                        )
                        continue
                    case .legacy:
                        break
                    }
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
                    if let chunkConfigTheme = chunk.terminalConfigTheme,
                       chunkConfigTheme != store.terminalConfigTheme(for: surfaceID) {
                        store.terminalOutputDidReset(
                            surfaceID: surfaceID,
                            streamToken: chunk.streamToken
                        )
                        continue
                    }
                    if !chunk.data.isEmpty || chunk.terminalConfigTheme != nil {
                        let applied = await surfaceView.processOutputAndWait(
                            chunk.data,
                            terminalConfigTheme: chunk.terminalConfigTheme
                        )
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
            surfaceView.requestViewportReportForMount()
        }

        private func stopMountedTasks() {
            tapGeneration &+= 1
            outputStartContinuation?.finish()
            outputStartContinuation = nil
            preparedViewportReportsByReportID.removeAll()
            outputTask?.cancel()
            outputTask = nil
            verifiedReplayState.invalidate()
            liveFontTask?.cancel()
            liveFontTask = nil
            viewportReportScheduler?.cancel()
            viewportReportScheduler = nil
            activeViewportPolicy = .natural
        }

        func detach() {
            onBottomScrollEdgeElementContainersChange?([])
            outputTask?.cancel()
            outputTask = nil
            liveFontTask?.cancel()
            liveFontTask = nil
            themeApplicationScheduler.cancel()
            viewportReportScheduler?.cancel()
            viewportReportScheduler = nil
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
#endif
