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

/// Mounts a `GhosttySurfaceHostView`, routes terminal output, and bridges the SwiftUI
/// composer into the host-owned bottom dock. Primary-screen output uses the
/// phone's natural height; alternate-screen replay can pin to the Mac's grid.
struct GhosttySurfaceRepresentable: UIViewRepresentable {
    let workspaceID: String
    let surfaceID: String
    let store: CMUXMobileShellStore
    let fontSize: Float32
    let terminalPresentationIsActive: Bool
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
    var terminalFolderTapEnabled: Bool = true
    var terminalFilesChipEnabled: Bool = true
    var showMissingFiles: Bool = false
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
            terminalPresentationIsActive: terminalPresentationIsActive,
            artifactFilesEnabled: artifactFilesEnabled,
            terminalFolderTapEnabled: terminalFolderTapEnabled,
            terminalFilesChipEnabled: terminalFilesChipEnabled,
            showMissingFiles: showMissingFiles,
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
        // Screen-anchored sessions scroll the local mirror's own scrollback
        // immediately (the Mac never repaints for a primary-screen scroll), so
        // they keep the low-latency local authority even under verified replay.
        view.scrollPresentationAuthority = store.usesVerifiedTerminalReplay
            && !store.usesScreenAnchoredRenderGrid
            ? .verifiedRenderGrid
            : .legacyMirror
        // Hand the surface the structured diagnostic log so the composer-dock
        // probes land in the blob the "Send to agent" feedback pane exports.
        // `nil` when no log is wired; every probe is then a no-op.
        view.diagnosticLog = store.diagnosticLog
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
        // The composition root's tracker spans host lifetimes, so a host built
        // for a reattached surface recovers keyboard transitions it missed.
        // Previews and isolated harnesses have no injected tracker; a
        // coordinator-owned instance still records for this mount's lifetime.
        return GhosttySurfaceHostView(
            surfaceView: view,
            keyboardFrameTracker: context.environment.mobileKeyboardFrameTracker
                ?? context.coordinator.fallbackKeyboardFrameTracker,
            keyboardDockRebuildRevertEnabled: context.environment.keyboardDockRebuildRevertEnabled
        )
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Bytes flow via the byte sink; the prop-driven mutations are the autofocus
        // suppression and the composer's open/closed state. `setComposerActive`
        // handles the first-responder handover that keeps the keyboard up; the
        // coordinator mounts/unmounts the hosted compose field into the surface's
        // composer band. This is a UIKit-internal mutation, not a sibling-observed
        // state write, so it is safe in `updateUIView`.
        context.coordinator.setTerminalPresentationActive(terminalPresentationIsActive)
        context.coordinator.attemptPendingOutputConsumerRecoveryPresentation()
        guard let surfaceView = (uiView as? GhosttySurfaceHostView)?.surfaceView else { return }
        surfaceView.autoFocusOnWindowAttach = autoFocusOnWindowAttach
        surfaceView.terminalTheme = terminalTheme
        surfaceView.terminalConfigTheme = terminalConfigTheme
        context.coordinator.onArtifactFilesRequested = onArtifactFilesRequested
        context.coordinator.onArtifactPathTapped = onArtifactPathTapped
        context.coordinator.onVisibleArtifactCountChanged = onVisibleArtifactCountChanged
        context.coordinator.onArtifactGalleryRefreshSignal = onArtifactGalleryRefreshSignal
        context.coordinator.terminalFolderTapEnabled = terminalFolderTapEnabled
        let artifactCountModeChanged = context.coordinator.updateArtifactCountMode(
            artifactFilesEnabled: artifactFilesEnabled,
            terminalFilesChipEnabled: terminalFilesChipEnabled,
            showMissingFiles: showMissingFiles,
            sessionArtifactCountEnabled: sessionArtifactCountEnabled
        )
        surfaceView.artifactFilesEnabled = artifactFilesEnabled
        // Alternate-screen apps own the whole grid, so the keyboard
        // blank-space absorption (top-pin while content is short) is
        // disabled for them; reading the store property here keeps the flag
        // live across mode flips.
        surfaceView.hostedAltScreenActive = store.isAlternateScreen(surfaceID: surfaceID)
        surfaceView.scrollPresentationAuthority = store.usesVerifiedTerminalReplay
            && !store.usesScreenAnchoredRenderGrid
            ? .verifiedRenderGrid
            : .legacyMirror
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
        (uiView as? GhosttySurfaceHostView)?.surfaceView.prepareForDismantle()
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
        var terminalFolderTapEnabled: Bool
        var artifactChipGate: TerminalArtifactChipFeatureGate
        var showMissingFiles: Bool
        var sessionArtifactCountEnabled: Bool
        var visibleArtifactCount: Int
        var onArtifactFilesRequested: @MainActor (_ anchor: UnitPoint) -> Void
        var onArtifactPathTapped: @MainActor (_ path: String) -> Void
        var onVisibleArtifactCountChanged: @MainActor (_ count: Int) -> Void
        var onArtifactGalleryRefreshSignal: @MainActor (TerminalArtifactGalleryRefreshSignal) -> Void
        private var outputTask: Task<Void, Never>?
        private var outputConsumerOwnerID: UUID?
        /// Monotonic owner for the mounted output consumer. A stream can end
        /// independently of UIKit (for example when its continuation is
        /// replaced); the generation lets its exit handler restart only the
        /// still-current mount and never resurrect a deliberately dismantled
        /// surface.
        private var outputTaskGeneration: UInt64 = 0
        private var outputConsumerRestartTask: Task<Void, Never>?
        private var outputConsumerStabilityTask: Task<Void, Never>?
        private var outputConsumerRestartAttempts = 0
        /// A persistently terminating stream is held at a lifecycle boundary
        /// after the bounded restart budget is exhausted. Without this latch,
        /// the recovery branch would reset the counter and spin forever.
        var outputConsumerRestartBlocked = false
        /// UIKit recovery alert currently owned by this mounted surface. The
        /// alert is the explicit user action that clears a persistent stream
        /// failure while the view remains in the window.
        weak var outputConsumerRecoveryAlert: UIAlertController?
        /// Set when recovery is blocked but UIKit did not have a presenter at
        /// the time the bounded presentation queue expired. Lifecycle updates
        /// retry this synchronously without creating an unbounded timer loop.
        var outputConsumerRecoveryAlertPending = false
        var outputConsumerRecoveryPresentationTask: Task<Void, Never>?
        /// In-surface recovery affordance kept visible when UIKit cannot present
        /// the alert (for example while another modal is transitioning).
        var outputConsumerRecoveryOverlay: UIView?
        private static let outputConsumerRestartDelays: [Duration] = [
            .zero,
            .milliseconds(100),
            .milliseconds(250),
            .seconds(1),
            .seconds(2),
        ]
        private static let maximumOutputConsumerRestartAttempts =
            outputConsumerRestartDelays.count
        private static let outputConsumerStabilityDuration: Duration = .seconds(2)
        /// UIKit can take a few run-loop turns to finish a sheet transition.
        /// Keep presenter discovery bounded so a surface that never gets a
        /// presenter cannot retain its coordinator forever.
        static let maximumOutputConsumerRecoveryPresentationAttempts = 20
        static let outputConsumerRecoveryPresentationRetryInterval: Duration =
            .milliseconds(250)
        private static let outputStartViewportTimeout: Duration = .seconds(1)
        private static let maximumOutputStartViewportTimeouts = 3
        /// The first viewport report gates the initial stream registration so
        /// the Mac is never asked to replay before the surface has a valid
        /// grid. A consumer restart on the same mounted surface may reuse that
        /// established viewport and must not wait for a resize callback that
        /// will never be emitted again.
        var outputStartReady = false
        var terminalPresentationIsActive: Bool
        var outputStartContinuation: AsyncStream<Void>.Continuation?
        var outputStartViewportTimeouts = 0
        var outputStartMinimumViewportReportID: UInt64?
        var preparedViewportReportsByReportID: [UInt64: MobileTerminalViewportPreparation] = [:]
        /// The replay state machine's negotiation generation each in-flight
        /// viewport report was recorded under (keyed by report ID). Passed
        /// back with the report's acknowledgement so an answer from a
        /// previous mount can never settle the current negotiation. Consumed
        /// on reply; cleared when the report scheduler is rebuilt.
        var viewportReportGenerationsByReportID: [UInt64: UInt64] = [:]
        private var liveFontTask: Task<Void, Never>?
        let themeApplicationScheduler = TerminalThemeApplicationScheduler()
        var artifactCountTask: Task<Void, Never>?
        var artifactCountTaskRequest: TerminalArtifactChipCountState.Request?
        var artifactCountState = TerminalArtifactChipCountState()
        var artifactCountNeedsRefresh: Bool
        var freshestLocalArtifactCount = 0
        /// Async Mac clicks apply only for the newest tap and current mount.
        /// Keyboard intent is owned synchronously by the surface input session,
        /// so this generation can invalidate click work without starving focus.
        var clickGeneration: UInt64 = 0
        /// Hosts the SwiftUI ``TerminalComposerView`` so it can be installed into the
        /// surface's composer band. Built lazily on first open and torn down on
        /// dismantle; mounted/unmounted by ``setComposerMounted(_:)``.
        private var composerController: UIHostingController<TerminalComposerView>?
        var artifactChipController: UIHostingController<TerminalArtifactChipView>?
        var artifactChipVisibility = TerminalArtifactChipVisibilityState()
        /// Pending debounced chip unmount; cancelled whenever a positive count
        /// arrives so transient zero counts cannot flicker the chip.
        var artifactChipHideTask: Task<Void, Never>?
        /// Injected so the hide grace period is testable and cancellable
        /// (`DispatchQueue.asyncAfter` is banned for intentional delays).
        let artifactChipHideClock: any Clock<Duration>
        let outputConsumerRestartClock: any Clock<Duration>
        let outputConsumerRecoveryClock: any Clock<Duration>
        private var composerMounted = false
        private var activeViewportPolicy: MobileTerminalOutputViewportPolicy = .natural
        private let verifiedReplayState = VerifiedTerminalReplayStateMachine()
        private var pendingReplayViewportAnchor: VerifiedReplayCapturedViewportAnchor?
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
        /// Keyboard frame record for mounts with no injected app-level tracker
        /// (previews, isolated harnesses). Lazy so production mounts, which
        /// receive the composition root's tracker, never build one.
        lazy var fallbackKeyboardFrameTracker = MobileKeyboardFrameTracker()

        init(
            workspaceID: String,
            surfaceID: String,
            store: CMUXMobileShellStore,
            terminalPresentationIsActive: Bool = true,
            artifactFilesEnabled: Bool,
            terminalFolderTapEnabled: Bool,
            terminalFilesChipEnabled: Bool,
            showMissingFiles: Bool = false,
            sessionArtifactCountEnabled: Bool,
            visibleArtifactCount: Int,
            onArtifactFilesRequested: @escaping @MainActor (_ anchor: UnitPoint) -> Void,
            onArtifactPathTapped: @escaping @MainActor (_ path: String) -> Void,
            onVisibleArtifactCountChanged: @escaping @MainActor (_ count: Int) -> Void,
            onArtifactGalleryRefreshSignal: @escaping @MainActor (TerminalArtifactGalleryRefreshSignal) -> Void,
            artifactChipHideClock: any Clock<Duration> = ContinuousClock(),
            outputConsumerRestartClock: any Clock<Duration> = ContinuousClock(),
            outputConsumerRecoveryClock: any Clock<Duration> = ContinuousClock()
        ) {
            self.workspaceID = workspaceID
            self.surfaceID = surfaceID
            self.store = store
            self.terminalPresentationIsActive = terminalPresentationIsActive
            self.artifactFilesEnabled = artifactFilesEnabled
            self.terminalFolderTapEnabled = terminalFolderTapEnabled
            self.artifactChipGate = TerminalArtifactChipFeatureGate(
                artifactsAvailable: artifactFilesEnabled,
                featureEnabled: terminalFilesChipEnabled
            )
            self.showMissingFiles = showMissingFiles
            self.sessionArtifactCountEnabled = sessionArtifactCountEnabled
            self.visibleArtifactCount = visibleArtifactCount
            self.artifactCountNeedsRefresh = artifactChipGate.isEnabled
            self.onArtifactFilesRequested = onArtifactFilesRequested
            self.onArtifactPathTapped = onArtifactPathTapped
            self.onVisibleArtifactCountChanged = onVisibleArtifactCountChanged
            self.onArtifactGalleryRefreshSignal = onArtifactGalleryRefreshSignal
            self.artifactChipHideClock = artifactChipHideClock
            self.outputConsumerRestartClock = outputConsumerRestartClock
            self.outputConsumerRecoveryClock = outputConsumerRecoveryClock
            super.init()
        }

        func attach(surfaceView: GhosttySurfaceView) {
            if let currentSurfaceView = self.surfaceView,
               currentSurfaceView !== surfaceView {
                stopMountedTasks()
            }
            self.surfaceView = surfaceView
            surfaceView.artifactFilesEnabled = artifactFilesEnabled
            updateArtifactChip(count: artifactCountNeedsRefresh ? 0 : visibleArtifactCount)
            guard terminalPresentationIsActive, surfaceView.window != nil else { return }
            startMountedTasks(
                surfaceView: surfaceView,
                resetRestartFailure: true
            )
        }

        private func startMountedTasks(
            surfaceView: GhosttySurfaceView,
            resetRestartFailure: Bool = false
        ) {
            guard terminalPresentationIsActive,
                  outputTask == nil else { return }
            if resetRestartFailure {
                outputConsumerRestartBlocked = false
                outputConsumerRestartAttempts = 0
                outputConsumerRecoveryAlertPending = false
            }
            guard !outputConsumerRestartBlocked else { return }
            guard let store else { return }
            // An explicit remount may race a delayed restart. The remount owns
            // the new consumer, so retire the pending replacement first.
            outputConsumerRestartTask?.cancel()
            outputConsumerRestartTask = nil
            outputConsumerStabilityTask?.cancel()
            outputConsumerStabilityTask = nil
            // `stopMountedTasks` invalidates the retired consumer so none of
            // its async completions can reveal. A mount is a new ownership
            // generation and must reactivate verification before its cold full
            // replay arrives. Reusing the permanent invalidated phase rejected
            // every post-background replay and left the frozen old viewport on
            // screen while the shell repeatedly reset the replay ack.
            verifiedReplayState.prepareForMount()
            pendingReplayViewportAnchor = nil
            outputStartViewportTimeouts = 0
            MobileDebugLog.anchormux(
                "verified_replay.mount_ready surface=\(surfaceID)"
            )
            // A stream can terminate without a UIKit detach. Its auxiliary
            // tasks belong to the old stream owner too, so retire them before
            // registering the replacement scheduler and live-font consumer.
            liveFontTask?.cancel()
            liveFontTask = nil
            viewportReportScheduler?.cancel()
            viewportReportScheduler = nil
            let surfaceID = surfaceID
            let outputStartSignal: AsyncStream<Void>?
            if outputStartReady {
                outputStartSignal = nil
            } else {
                outputStartSignal = AsyncStream { [weak self] continuation in
                    self?.outputStartContinuation = continuation
                }
            }
            viewportReportScheduler = TerminalViewportReportScheduler(
                send: { [weak self] report in
                    guard let self, let store = self.store else { return nil }
                    // The replay state machine compares incoming frame grids
                    // against the capacity this phone last told the daemon,
                    // so it can hold frames sized by stale daemon state (a
                    // reconnect replay captured before this report landed).
                    self.viewportReportGenerationsByReportID[report.id] =
                        self.verifiedReplayState.updateExpectedViewportDimensions(
                            columns: report.columns,
                            rows: report.rows,
                            reportID: report.id
                        )
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
                    // Consume the generation entry for EVERY reply: a
                    // confirmation without render metadata would otherwise
                    // strand its entry until remount.
                    let generation = self.viewportReportGenerationsByReportID
                        .removeValue(forKey: report.id) ?? 0
                    if let renderEpoch = effectiveGrid.renderEpoch,
                       let renderRevisionFloor = effectiveGrid.renderRevisionFloor {
                        self.verifiedReplayState.acknowledgeViewport(
                            renderEpoch: renderEpoch,
                            renderRevisionFloor: renderRevisionFloor,
                            reportID: report.id,
                            negotiationGeneration: generation,
                            reportedColumns: report.columns,
                            reportedRows: report.rows,
                            grantedColumns: effectiveGrid.columns,
                            grantedRows: effectiveGrid.rows
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
            outputTaskGeneration &+= 1
            let taskGeneration = outputTaskGeneration
            let ownerID = UUID()
            outputConsumerOwnerID = ownerID
            outputTask = Task { @MainActor [weak self, weak store] in
                defer {
                    self?.outputConsumerDidEnd(
                        generation: taskGeneration,
                        ownerID: ownerID,
                        cancelled: Task.isCancelled
                    )
                }
                if let outputStartSignal {
                    guard let self else { return }
                    guard await self.waitForOutputStart(
                        signal: outputStartSignal,
                        generation: taskGeneration
                    ) else { return }
                }
                guard !Task.isCancelled else { return }
                guard let store else { return }
                for await chunk in store.terminalOutputStream(
                    surfaceID: surfaceID,
                    ownerID: ownerID
                ) {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    guard store.isTerminalOutputConsumerOwner(
                        surfaceID: surfaceID,
                        ownerID: ownerID
                    ) else {
                        return
                    }
                    guard let surfaceView = self.surfaceView,
                          self.terminalPresentationIsActive else { return }
                    // Window attachment is owned by the delegate callbacks
                    // below. A transient reparent can make window nil for a
                    // turn without ending this mounted stream; stopping here
                    // would strand the sink until a later UIKit callback.
                    guard self.surfaceView === surfaceView else { return }
                    self.armOutputConsumerStabilityReset(generation: taskGeneration)
                    #if DEBUG
                    let latencySequence = chunk.sourceRenderGridFrame?.stateSeq
                        ?? chunk.endSequence
                        ?? 0
                    MobileLatencyTrace.stamp(
                        "ap.yield",
                        "s=\(surfaceID.prefix(8).lowercased()) seq=\(latencySequence)"
                    )
                    let latencyApplyStart = MobileLatencyTrace.captureTime()
                    #endif
                    switch terminalOutputApplicationPath(
                        for: chunk,
                        expectedSurfaceID: surfaceID
                    ) {
                    case .verifiedReplay:
                        guard let frame = chunk.sourceRenderGridFrame else {
                            // Routing is supposed to reject this shape before
                            // it reaches the consumer. Keep the consumer alive
                            // if a future producer violates that invariant,
                            // otherwise one malformed chunk freezes all later
                            // output until the workspace is remounted.
                            MobileDebugLog.anchormux(
                                "terminal.output.missing_verified_frame surface=\(surfaceID)"
                            )
                            store.terminalOutputDidReset(
                                surfaceID: surfaceID,
                                streamToken: chunk.streamToken
                            )
                            continue
                        }
                        let applied = await self.applyVerifiedRenderGrid(
                            frame,
                            chunk: chunk,
                            surfaceView: surfaceView,
                            store: store
                        )
                        if applied {
                            #if DEBUG
                            MobileLatencyTrace.stampElapsed(
                                "ap.done",
                                since: latencyApplyStart
                            ) {
                                "s=\(surfaceID.prefix(8).lowercased()) seq=\(frame.stateSeq) " +
                                    "path=verified us=\($0)"
                            }
                            // Verified replay has already submitted, read back,
                            // and revealed its tokened presentation before
                            // `applyVerifiedRenderGrid` returns. Stamp that exact
                            // frame here, after `ap.done`, instead of associating
                            // it with a later ordinary redraw.
                            MobileLatencyTrace.stamp(
                                "rd.present",
                                "s=\(surfaceID.prefix(8).lowercased()) seq=\(frame.stateSeq)"
                            )
                            #endif
                            store.terminalOutputDidProcess(
                                surfaceID: surfaceID,
                                streamToken: chunk.streamToken
                            )
                        }
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
                        if chunk.requiresVerifiedReplayReset {
                            // An exhausted compatibility replay is not a
                            // render-grid baseline. Drop the verifier's old
                            // epoch/snapshot and any retained frozen pixels
                            // before the legacy bytes repaint the surface.
                            self.verifiedReplayState.resetForCompatibilityFallback()
                            surfaceView.resetVerifiedReplayPresentationForCompatibilityFallback()
                        }
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
                    #if DEBUG
                    surfaceView.markLatencyAppliedSequence(latencySequence)
                    MobileLatencyTrace.stampElapsed(
                        "ap.done",
                        since: latencyApplyStart
                    ) {
                        "s=\(surfaceID.prefix(8).lowercased()) seq=\(latencySequence) " +
                            "path=legacy us=\($0)"
                    }
                    #endif
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
            outputStartMinimumViewportReportID =
                surfaceView.requestViewportReportForMount()
        }

        /// Called by the recovery alert's Retry action. A retry is an explicit
        /// ownership boundary, so it may clear the persistent failure latch and
        /// register a fresh stream while the UIKit surface stays mounted.
        func retryMountedOutputConsumer(surfaceView: GhosttySurfaceView) {
            guard self.surfaceView === surfaceView,
                  terminalPresentationIsActive,
                  surfaceView.window != nil else { return }
            outputConsumerRecoveryAlert = nil
            outputConsumerRecoveryAlertPending = false
            removeOutputConsumerRecoveryOverlay()
            startMountedTasks(
                surfaceView: surfaceView,
                resetRestartFailure: true
            )
        }

        /// Reclaims a consumer whose stream ended while its UIKit surface stayed
        /// mounted. The stream's continuation is the authoritative ownership
        /// edge, so a fresh consumer also requests a cold replay and restores
        /// any output missed between the two registrations.
        private func outputConsumerDidEnd(
            generation: UInt64,
            ownerID: UUID,
            cancelled: Bool
        ) {
            guard outputTaskGeneration == generation else { return }
            outputTask = nil
            guard !cancelled,
                  terminalPresentationIsActive,
                  let surfaceView,
                  self.surfaceView === surfaceView,
                  surfaceView.window != nil,
                  let store,
                  store.isTerminalOutputConsumerOwner(
                      surfaceID: surfaceID,
                      ownerID: ownerID
                  ) else {
                return
            }
            MobileDebugLog.anchormux(
                "terminal.output.consumer_restarted surface=\(surfaceID)"
            )
            scheduleOutputConsumerRestart(
                surfaceView: surfaceView,
                generation: generation
            )
        }

        /// The first geometry callback opens the output gate. A transiently lost
        /// callback retries the report, but never admits replay without a
        /// validated viewport. After bounded retries the existing recovery
        /// alert gives the user an explicit lifecycle boundary.
        private func waitForOutputStart(
            signal: AsyncStream<Void>,
            generation: UInt64
        ) async -> Bool {
            let clock = outputConsumerRestartClock
            while !Task.isCancelled,
                  outputTaskGeneration == generation,
                  !outputStartReady {
                let timedOut = await withTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        for await _ in signal {
                            return false
                        }
                        return false
                    }
                    group.addTask {
                        do {
                            try await clock.sleep(
                                for: Self.outputStartViewportTimeout,
                                tolerance: nil
                            )
                            return true
                        } catch {
                            return false
                        }
                    }
                    let result = await group.next() ?? false
                    group.cancelAll()
                    return result
                }
                guard !Task.isCancelled,
                      outputTaskGeneration == generation else {
                    return false
                }
                guard timedOut else {
                    return outputStartReady
                }
                guard !outputStartReady else { return true }

                outputStartViewportTimeouts += 1
                surfaceView?.retryViewportReport()
                surfaceView?.requestViewportReportForMount(
                    invalidatingPendingReports: false
                )
                MobileDebugLog.anchormux(
                    "terminal.output.start_viewport_timeout surface=\(surfaceID) "
                        + "attempt=\(outputStartViewportTimeouts)/\(Self.maximumOutputStartViewportTimeouts)"
                )
                guard outputStartViewportTimeouts < Self.maximumOutputStartViewportTimeouts else {
                    outputConsumerRestartBlocked = true
                    outputStartContinuation?.finish()
                    outputStartContinuation = nil
                    // The output task is currently waiting in this method, so
                    // its sibling font and viewport consumers would otherwise
                    // survive the permanent recovery latch until detach.
                    stopMountedTasks()
                    if let surfaceView {
                        ghosttySurfaceViewDidExhaustOutputConsumerRecovery(surfaceView)
                    }
                    MobileDebugLog.anchormux(
                        "terminal.output.start_viewport_blocked surface=\(surfaceID)"
                    )
                    return false
                }
            }
            return outputStartReady
        }

        /// Resets the restart budget only after a replacement consumer has
        /// stayed alive for a meaningful interval. A stream that yields one
        /// chunk and dies must still consume the bounded budget rather than
        /// resetting it on every short-lived replacement.
        private func armOutputConsumerStabilityReset(generation: UInt64) {
            guard outputConsumerStabilityTask == nil else { return }
            let clock = outputConsumerRestartClock
            outputConsumerStabilityTask = Task { @MainActor [weak self] in
                defer {
                    if let self {
                        self.outputConsumerStabilityTask = nil
                    }
                }
                do {
                    try await clock.sleep(
                        for: Self.outputConsumerStabilityDuration,
                        tolerance: nil
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      let self,
                      self.outputTaskGeneration == generation,
                      self.outputTask != nil else {
                    return
                }
                self.outputConsumerRestartAttempts = 0
            }
        }

        /// Schedule one replacement consumer with bounded backoff. The first
        /// replacement remains immediate for normal stream turnover; later
        /// replacements yield the main actor so a broken continuation cannot
        /// monopolize rendering.
        private func scheduleOutputConsumerRestart(
            surfaceView: GhosttySurfaceView,
            generation: UInt64
        ) {
            guard outputConsumerRestartTask == nil else {
                return
            }
            guard !outputConsumerRestartBlocked else { return }
            guard outputConsumerRestartAttempts
                    < Self.maximumOutputConsumerRestartAttempts else {
                outputConsumerStabilityTask?.cancel()
                outputConsumerStabilityTask = nil
                MobileDebugLog.anchormux(
                    "terminal.output.consumer_restart_blocked surface=\(surfaceID)"
                )
                // Stop all auxiliary work and wait for an explicit mount or
                // window-attachment transition to establish a new ownership
                // boundary. A broken continuation must never create an
                // unbounded stream/replay loop in the background.
                outputConsumerRestartBlocked = true
                stopMountedTasks()
                ghosttySurfaceViewDidExhaustOutputConsumerRecovery(surfaceView)
                return
            }
            let attempt = outputConsumerRestartAttempts
            outputConsumerRestartAttempts += 1
            if attempt == 0 {
                startMountedTasks(surfaceView: surfaceView)
                return
            }
            let delay = Self.outputConsumerRestartDelays[attempt]
            let clock = outputConsumerRestartClock
            outputConsumerRestartTask = Task { @MainActor [weak self, weak surfaceView] in
                defer {
                    if let self {
                        self.outputConsumerRestartTask = nil
                    }
                }
                do {
                    try await clock.sleep(for: delay, tolerance: nil)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      let self,
                      let surfaceView,
                      self.outputTaskGeneration == generation,
                      self.terminalPresentationIsActive,
                      self.surfaceView === surfaceView,
                      surfaceView.window != nil,
                      self.outputTask == nil else {
                    return
                }
                self.startMountedTasks(surfaceView: surfaceView)
            }
        }

        private func stopMountedTasks() {
            let releasesViewport = outputTask != nil || viewportReportScheduler != nil
            let ownerID = outputConsumerOwnerID
            outputConsumerOwnerID = nil
            outputTaskGeneration &+= 1
            outputStartReady = false
            outputStartViewportTimeouts = 0
            outputStartMinimumViewportReportID = nil
            clickGeneration &+= 1
            outputStartContinuation?.finish()
            outputStartContinuation = nil
            preparedViewportReportsByReportID.removeAll()
            viewportReportGenerationsByReportID.removeAll()
            outputTask?.cancel()
            outputTask = nil
            outputConsumerRecoveryAlert?.dismiss(animated: false)
            outputConsumerRecoveryAlert = nil
            removeOutputConsumerRecoveryOverlay()
            outputConsumerRecoveryPresentationTask?.cancel()
            outputConsumerRecoveryPresentationTask = nil
            outputConsumerRestartTask?.cancel()
            outputConsumerRestartTask = nil
            outputConsumerStabilityTask?.cancel()
            outputConsumerStabilityTask = nil
            outputConsumerRestartAttempts = 0
            verifiedReplayState.invalidate()
            pendingReplayViewportAnchor = nil
            liveFontTask?.cancel()
            liveFontTask = nil
            viewportReportScheduler?.cancel()
            viewportReportScheduler = nil
            if let ownerID {
                store?.clearTerminalOutputConsumerOwner(
                    surfaceID: surfaceID,
                    ownerID: ownerID
                )
            }
            activeViewportPolicy = .natural
            if releasesViewport {
                store?.clearTerminalViewport(surfaceID: surfaceID)
            }
        }

        func setTerminalPresentationActive(_ isActive: Bool) {
            guard terminalPresentationIsActive != isActive else { return }
            terminalPresentationIsActive = isActive
            guard let surfaceView else { return }
            if isActive {
                guard surfaceView.window != nil else { return }
                // A blocked consumer is an explicit recovery state. A
                // presentation update must not silently clear its bounded
                // retry budget; only a real window remount or Retry owns that
                // reset. Keep the pending alert alive across backgrounding.
                guard !outputConsumerRestartBlocked,
                      !outputConsumerRecoveryAlertPending else {
                    attemptPendingOutputConsumerRecoveryPresentation()
                    return
                }
                startMountedTasks(
                    surfaceView: surfaceView,
                    resetRestartFailure: true
                )
                attemptPendingOutputConsumerRecoveryPresentation()
            } else {
                outputConsumerRecoveryAlertPending = outputConsumerRestartBlocked
                stopMountedTasks()
            }
        }

        func detach() {
            outputConsumerRecoveryAlertPending = false
            stopMountedTasks()
            surfaceView = nil
            themeApplicationScheduler.cancel()
            artifactCountTask?.cancel()
            artifactCountTask = nil
            artifactCountTaskRequest = nil
            artifactCountState.reset()
            surfaceView = nil
        }

        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didChangeWindowAttachment isAttached: Bool
        ) {
            guard self.surfaceView === surfaceView else { return }
            if isAttached {
                startMountedTasks(
                    surfaceView: surfaceView,
                    resetRestartFailure: true
                )
                attemptPendingOutputConsumerRecoveryPresentation()
            } else {
                outputConsumerRecoveryAlertPending = false
                stopMountedTasks()
            }
        }

        private func applyVerifiedRenderGrid(
            _ frame: MobileTerminalRenderGridFrame,
            chunk: MobileTerminalOutputChunk,
            surfaceView: GhosttySurfaceView,
            store: CMUXMobileShellStore
        ) async -> Bool {
            if let chunkConfigTheme = chunk.terminalConfigTheme,
               chunkConfigTheme != store.terminalConfigTheme(for: surfaceID) {
                store.terminalOutputDidReset(
                    surfaceID: surfaceID,
                    streamToken: chunk.streamToken
                )
                return false
            }
            return await applyThemeMatchedVerifiedRenderGrid(
                frame,
                chunk: chunk,
                surfaceView: surfaceView,
                store: store
            )
        }

        private func applyThemeMatchedVerifiedRenderGrid(
            _ frame: MobileTerminalRenderGridFrame,
            chunk: MobileTerminalOutputChunk,
            surfaceView: GhosttySurfaceView,
            store: CMUXMobileShellStore
        ) async -> Bool {
            let transaction: VerifiedTerminalReplayTransaction
            switch verifiedReplayState.begin(frame: frame) {
            case .apply(let began):
                transaction = began
            case .renegotiateViewportAndKeepFrozen:
                // The frame is sized by stale daemon state (its grid does not
                // match the capacity this phone last reported, and no report
                // for its epoch has been acknowledged). Keep the last
                // verified pixels on screen and re-send the capacity report;
                // the acknowledged negotiation floors these stale captures
                // and the replay barrier requests a fresh frame at the
                // settled grid.
                MobileDebugLog.anchormux(
                    "verified_replay.hold_stale_grid surface=\(surfaceID) "
                        + "grid=\(frame.columns)x\(frame.rows) epoch=\(frame.renderEpoch)"
                )
                surfaceView.reassertViewportCapacityReport()
                _ = await surfaceView.freezeVerifiedReplayPresentation(
                    transactionID: frame.renderRevision
                )
                guard !Task.isCancelled else { return false }
                requestVerifiedReplayReset(transactionID: nil, chunk: chunk, store: store)
                return false
            case .keepFrozenAndRequestReplay:
                _ = await surfaceView.freezeVerifiedReplayPresentation(
                    transactionID: frame.renderRevision
                )
                guard !Task.isCancelled else { return false }
                requestVerifiedReplayReset(transactionID: nil, chunk: chunk, store: store)
                return false
            }

            let frozen = await surfaceView.freezeVerifiedReplayPresentation(
                transactionID: transaction.id
            )
            guard !Task.isCancelled else { return false }
            guard frozen else {
                requestVerifiedReplayReset(transactionID: transaction.id, chunk: chunk, store: store)
                return false
            }
            activeViewportPolicy = .remoteGrid(columns: frame.columns, rows: frame.rows)
            let resized = await surfaceView.applyViewSizeAndWait(
                cols: frame.columns,
                rows: frame.rows
            )
            guard !Task.isCancelled else { return false }
            guard resized else {
                requestVerifiedReplayReset(transactionID: transaction.id, chunk: chunk, store: store)
                return false
            }

            // Capture reads the post-reflow scrollbar, so Ghostty's resize pin
            // remap is authoritative and anchor math never sees reflow as append drift.
            let capturedViewportAnchor =
                await surfaceView.captureVerifiedReplayViewportAnchor()
            guard !Task.isCancelled else { return false }
            let replayViewportAnchor: VerifiedReplayCapturedViewportAnchor?
            if frame.anchor == .screen, frame.activeScreen == .primary {
                if let capturedViewportAnchor {
                    pendingReplayViewportAnchor = capturedViewportAnchor
                }
                replayViewportAnchor = pendingReplayViewportAnchor
            } else {
                pendingReplayViewportAnchor = nil
                replayViewportAnchor = nil
            }

            if !chunk.data.isEmpty || chunk.terminalConfigTheme != nil {
                let applied = await surfaceView.processOutputAndWait(
                    chunk.data,
                    terminalConfigTheme: chunk.terminalConfigTheme
                )
                guard !Task.isCancelled else { return false }
                guard applied else {
                    requestVerifiedReplayReset(transactionID: transaction.id, chunk: chunk, store: store)
                    return false
                }
            }

            let observed = await surfaceView.presentVerifiedReplayAndReadBack(
                frame: frame,
                configuredCursorColor: chunk.terminalConfigTheme?.cursor
                    ?? surfaceView.terminalConfigTheme.cursor
            )
            guard !Task.isCancelled else { return false }
            return await finishVerifiedReplay(
                transactionID: transaction.id,
                observed: observed,
                viewportAnchor: replayViewportAnchor,
                chunk: chunk,
                surfaceView: surfaceView,
                store: store
            )
        }

        private func requestVerifiedReplayReset(
            transactionID: UInt64?,
            chunk: MobileTerminalOutputChunk,
            store: CMUXMobileShellStore
        ) {
            if let transactionID {
                _ = verifiedReplayState.complete(
                    transactionID: transactionID,
                    observedFrame: nil
                )
            }
            store.terminalOutputDidReset(
                surfaceID: surfaceID,
                streamToken: chunk.streamToken
            )
        }

        private func finishVerifiedReplay(
            transactionID: UInt64,
            observed: MobileTerminalRenderGridFrame?,
            viewportAnchor: VerifiedReplayCapturedViewportAnchor?,
            chunk: MobileTerminalOutputChunk,
            surfaceView: GhosttySurfaceView,
            store: CMUXMobileShellStore
        ) async -> Bool {
            switch verifiedReplayState.complete(
                transactionID: transactionID,
                observedFrame: observed
            ) {
            case .reveal:
                var needsPresentationReFence = false
                if let viewportAnchor {
                    let restored = await surfaceView.restoreVerifiedReplayViewportAnchor(
                        viewportAnchor
                    )
                    guard !Task.isCancelled else { return false }
                    if restored {
                        pendingReplayViewportAnchor = nil
                        needsPresentationReFence = true
                    }
                }
                if await surfaceView.drainPendingScrollForVerifiedReplayReveal() {
                    needsPresentationReFence = true
                }
                if needsPresentationReFence {
                    // Restore/scroll and re-fence happen under render suppression,
                    // so the renderer identity cannot change before reveal.
                    let refenced = await surfaceView.presentRestoredVerifiedReplayViewport()
                    guard !Task.isCancelled else { return false }
                    guard refenced else {
                        _ = verifiedReplayState.rejectUnverifiedOutput()
                        store.terminalOutputDidReset(
                            surfaceID: surfaceID,
                            streamToken: chunk.streamToken
                        )
                        return false
                    }
                }
                guard surfaceView.revealVerifiedReplayPresentation(
                    transactionID: transactionID
                ) else {
                    _ = verifiedReplayState.rejectUnverifiedOutput()
                    store.terminalOutputDidReset(
                        surfaceID: surfaceID,
                        streamToken: chunk.streamToken
                    )
                    return false
                }
                return true
            case .keepFrozenAndRequestReplay, .ignoreStaleCompletion:
                store.terminalOutputDidReset(
                    surfaceID: surfaceID,
                    streamToken: chunk.streamToken
                )
                return false
            }
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
            let view = TerminalComposerView(
                store: store,
                terminalID: surfaceID,
                requestHeightRemeasure: { [weak self] in
                    // Content changed (a line added/removed, or cleared after send): live
                    // grows/shrinks animate. `setComposerBandHeight` is idempotent on
                    // unchanged heights, so a no-op change is harmless.
                    self?.reportComposerHeight(animated: true)
                },
                requestInputFocus: { [weak self] in
                    self?.surfaceView?.requestComposerInputFocus()
                },
                inputFocusChanged: { [weak self] focused in
                    self?.surfaceView?.composerInputFocusChanged(focused)
                },
                photoPickerWillPresent: { [weak self] in
                    self?.surfaceView?.photoPickerWillPresent()
                },
                photoPickerDidPresent: { [weak self] in
                    self?.surfaceView?.photoPickerDidPresent()
                },
                photoPickerDidDismiss: { [weak self] in
                    self?.surfaceView?.photoPickerDidDismiss()
                }
            )
            let controller = UIHostingController(rootView: view)
            // The field is pinned edge-to-edge in the band, so the band frame (not an
            // intrinsic size) drives the hosting view's height; the measured ideal
            // height flows separately through `sizeThatFits`. Clear background so the
            // terminal/glass shows through.
            controller.view.backgroundColor = .clear
            // Keyboard geometry is owned explicitly by the surface's frame math;
            // opting out here prevents the hosted field from avoiding it a second time.
            controller.safeAreaRegions = .container
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
            let clampedHeight = min(
                fitting.height,
                floor(surfaceView.bounds.height * 0.45)
            )
            if clampedHeight < fitting.height {
                MobileDebugLog.anchormux(
                    "composer.bandHeightClamped measured=\(fitting.height) clamped=\(clampedHeight)"
                )
            }
            surfaceView.setComposerBandHeight(clampedHeight, animated: animated)
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
