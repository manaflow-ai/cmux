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

/// Mounts a `GhosttySurfaceView`, routes terminal output, and bridges the SwiftUI
/// composer into the surface-owned bottom dock. Primary-screen output uses the
/// phone's natural height; alternate-screen replay can pin to the Mac's grid.
struct GhosttySurfaceRepresentable: UIViewRepresentable {
    let workspaceID: String
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
    var artifactFilesEnabled: Bool = false
    var terminalFilesChipEnabled: Bool = false
    var sessionArtifactCountEnabled: Bool = false
    var visibleArtifactCount: Int = 0
    var onArtifactFilesRequested: @MainActor (_ anchor: UnitPoint) -> Void = { _ in }
    var onArtifactPathTapped: @MainActor (_ path: String) -> Void = { _ in }
    var onVisibleArtifactCountChanged: @MainActor (_ count: Int) -> Void = { _ in }
    var onArtifactGalleryRefreshSignal: @MainActor (TerminalArtifactGalleryRefreshSignal) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            store: store,
            artifactFilesEnabled: artifactFilesEnabled,
            terminalFilesChipEnabled: terminalFilesChipEnabled,
            sessionArtifactCountEnabled: sessionArtifactCountEnabled,
            visibleArtifactCount: visibleArtifactCount,
            onArtifactFilesRequested: onArtifactFilesRequested,
            onArtifactPathTapped: onArtifactPathTapped,
            onVisibleArtifactCountChanged: onVisibleArtifactCountChanged,
            onArtifactGalleryRefreshSignal: onArtifactGalleryRefreshSignal
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
        surfaceView.autoFocusOnWindowAttach = autoFocusOnWindowAttach
        surfaceView.terminalTheme = terminalTheme
        surfaceView.terminalConfigTheme = terminalConfigTheme
        context.coordinator.onArtifactFilesRequested = onArtifactFilesRequested
        context.coordinator.onArtifactPathTapped = onArtifactPathTapped
        context.coordinator.onVisibleArtifactCountChanged = onVisibleArtifactCountChanged
        context.coordinator.onArtifactGalleryRefreshSignal = onArtifactGalleryRefreshSignal
        let artifactCountModeChanged = context.coordinator.updateArtifactCountMode(
            artifactFilesEnabled: artifactFilesEnabled,
            terminalFilesChipEnabled: terminalFilesChipEnabled,
            sessionArtifactCountEnabled: sessionArtifactCountEnabled
        )
        surfaceView.artifactFilesEnabled = artifactFilesEnabled
        if artifactCountModeChanged {
            surfaceView.resetVisibleArtifactCountTracking()
        }
        let projectedArtifactCount = context.coordinator.artifactCountNeedsRefresh
            ? 0
            : visibleArtifactCount
        context.coordinator.updateArtifactChip(count: projectedArtifactCount)
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
        coordinator.tearDownArtifactChip()
        coordinator.tearDownComposer()
        coordinator.detach()
    }

    final class Coordinator: NSObject, GhosttySurfaceViewDelegate {
        let workspaceID: String
        let surfaceID: String
        weak var store: CMUXMobileShellStore?
        weak var surfaceView: GhosttySurfaceView?
        var artifactFilesEnabled: Bool
        var artifactChipGate: TerminalArtifactChipFeatureGate
        var sessionArtifactCountEnabled: Bool
        var visibleArtifactCount: Int
        var onArtifactFilesRequested: @MainActor (_ anchor: UnitPoint) -> Void
        var onArtifactPathTapped: @MainActor (_ path: String) -> Void
        var onVisibleArtifactCountChanged: @MainActor (_ count: Int) -> Void
        var onArtifactGalleryRefreshSignal: @MainActor (TerminalArtifactGalleryRefreshSignal) -> Void
        private var outputTask: Task<Void, Never>?
        private var liveFontTask: Task<Void, Never>?
        let themeApplicationScheduler = TerminalThemeApplicationScheduler()
        var artifactCountTask: Task<Void, Never>?
        var artifactCountTaskRequest: TerminalArtifactChipCountState.Request?
        var artifactCountState = TerminalArtifactChipCountState()
        var artifactCountNeedsRefresh: Bool
        var freshestLocalArtifactCount = 0
        /// Hosts the SwiftUI ``TerminalComposerView`` so it can be installed into the
        /// surface's composer band. Built lazily on first open and torn down on
        /// dismantle; mounted/unmounted by ``setComposerMounted(_:)``.
        private var composerController: UIHostingController<TerminalComposerView>?
        var artifactChipController: UIHostingController<TerminalArtifactChipView>?
        var lastArtifactChipRender: (count: Int, enabled: Bool)?
        private var composerMounted = false
        private var activeViewportPolicy: MobileTerminalOutputViewportPolicy = .natural
        /// Serializes the natural-grid viewport reports and their echoes. One
        /// detached Task per report (the previous shape) let Task scheduling
        /// scramble the send order AND let the echo of an old keyboard-up
        /// report resolve after the newer keyboard-down echo, permanently
        /// re-pinning the phone to the stale smaller grid (empty space above
        /// the terminal). Built on attach, torn down on detach.
        var viewportReportScheduler: TerminalViewportReportScheduler?
        /// Bumped on every mount/unmount transition so a deferred close completion
        /// can tell whether it is still the latest transition. Guards the
        /// close-then-quickly-reopen race: an interrupted close animation still runs
        /// its completion, which must not unmount a composer that was remounted in
        /// the meantime.
        private var composerMountGeneration = 0

        init(
            workspaceID: String,
            surfaceID: String,
            store: CMUXMobileShellStore,
            artifactFilesEnabled: Bool,
            terminalFilesChipEnabled: Bool,
            sessionArtifactCountEnabled: Bool,
            visibleArtifactCount: Int,
            onArtifactFilesRequested: @escaping @MainActor (_ anchor: UnitPoint) -> Void,
            onArtifactPathTapped: @escaping @MainActor (_ path: String) -> Void,
            onVisibleArtifactCountChanged: @escaping @MainActor (_ count: Int) -> Void,
            onArtifactGalleryRefreshSignal: @escaping @MainActor (TerminalArtifactGalleryRefreshSignal) -> Void
        ) {
            self.workspaceID = workspaceID
            self.surfaceID = surfaceID
            self.store = store
            self.artifactFilesEnabled = artifactFilesEnabled
            self.artifactChipGate = TerminalArtifactChipFeatureGate(
                artifactsAvailable: artifactFilesEnabled,
                preferenceEnabled: terminalFilesChipEnabled
            )
            self.sessionArtifactCountEnabled = sessionArtifactCountEnabled
            self.visibleArtifactCount = visibleArtifactCount
            self.artifactCountNeedsRefresh = artifactChipGate.isEnabled
            self.onArtifactFilesRequested = onArtifactFilesRequested
            self.onArtifactPathTapped = onArtifactPathTapped
            self.onVisibleArtifactCountChanged = onVisibleArtifactCountChanged
            self.onArtifactGalleryRefreshSignal = onArtifactGalleryRefreshSignal
            super.init()
        }

        func attach(surfaceView: GhosttySurfaceView) {
            self.surfaceView = surfaceView
            surfaceView.artifactFilesEnabled = artifactFilesEnabled
            updateArtifactChip(count: artifactCountNeedsRefresh ? 0 : visibleArtifactCount)
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
        }

        func detach() {
            outputTask?.cancel()
            outputTask = nil
            liveFontTask?.cancel()
            liveFontTask = nil
            themeApplicationScheduler.cancel()
            artifactCountTask?.cancel()
            artifactCountTask = nil
            artifactCountTaskRequest = nil
            artifactCountState.reset()
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

    }
}
#endif
