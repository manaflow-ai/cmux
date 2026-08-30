#if canImport(UIKit)
import CMUXMobileCore
import CmuxAgentChat
import CmuxMobileDiagnostics
import CmuxMobileSupport
import CmuxMobileTerminalKit
import GhosttyKit
import OSLog
import Synchronization
import UIKit
import os

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "ghostty.surface")

public final class GhosttySurfaceView: UIView, TerminalSurfaceHosting {
    /// The surface whose terminal proxy or composer currently owns input.
    ///
    /// Tracked statically so chrome (SwiftUI overlays presented over the
    /// terminal) can dismiss the live keyboard via ``resignActiveInput()``
    /// without holding a reference to the specific surface.
    private static weak var activeInputSurface: GhosttySurfaceView?
    private weak var runtime: GhosttyRuntime?
    /// Renderer-effective colors used by this surface and its UIKit chrome.
    public var terminalTheme: TerminalTheme = .monokai {
        didSet { if terminalTheme != oldValue { inputProxy.terminalTheme = terminalTheme; refreshThemeColors() } }
    }
    /// Raw Ghostty configuration defaults for this mirror surface.
    ///
    /// This remains separate from ``terminalTheme``, which includes dynamic
    /// reverse-video and OSC colors used by surrounding UIKit chrome.
    public var terminalConfigTheme: TerminalTheme = .monokai
    /// Verified sessions keep the Mac as the sole owner of terminal scroll state.
    public var scrollPresentationAuthority: TerminalScrollPresentationAuthority = .legacyMirror
    private var appliedTerminalConfigTheme: TerminalTheme?
    weak var delegate: GhosttySurfaceViewDelegate?
    private let fontSize: Float32
    /// Surface-owned live font size (points). Zoom mutates this; it is the
    /// source of truth for the current size, so the size accumulates correctly
    /// across taps even though the actual libghostty apply is coalesced.
    var liveFontSize: Float32
    /// The user's EXPLICIT font choice: the init font until a pinch, accessory
    /// zoom step, overlay reset, or Mac-pushed `set_font` changes it. The
    /// rendered font never moves off this baseline on its own (no auto-fit),
    /// and viewport reports advertise the row capacity at THIS size (see
    /// `TerminalRowCapacityFit`) so the daemon negotiation can always recover
    /// when the constraining device grows.
    var userBaseFontSize: Float32
    /// Latest zoom target awaiting a coalesced apply. The display link applies
    /// it once per frame via an absolute `set_font_size` so a burst of zoom
    /// taps becomes one libghostty push + resize per frame, instead of one per
    /// tap. That keeps the serial `outputQueue` from accumulating blocking
    /// pushes (mailbox `.forever` push / swap-chain wait) faster than the
    /// per-frame render drains them — the wedge that froze zoom.
    var pendingFontSize: Float32?
    /// Countdown of quiet frames before the post-zoom geometry resync fires.
    /// A zoom step changes the cell size, which (when letterbox-pinned to the
    /// Mac's grid) changes `renderRect` and so reallocates the IOSurface render
    /// target. Doing that every step thrashed the GPU and wedged
    /// `render_now`'s synchronous frame wait. Instead each step only applies
    /// the font (the grid reflows inside the current surface) and arms this
    /// counter; the display link runs ONE `setNeedsGeometrySync` once zoom goes
    /// quiet, so the letterbox re-pins a single time. nil = nothing pending.
    private var zoomSettleFrames: Int?
    private static let zoomSettleFrameThreshold = 6
    /// The transient zoom-control HUD (reset/save/restore-built-in), created
    /// lazily on the first zoom. Centered over the surface; auto-fades.
    private var zoomOverlay: MobileTerminalZoomControlOverlay?
    /// Whether the zoom HUD is currently presented (alpha animating toward 1).
    private var zoomOverlayShown = false
    /// Media time of the last zoom interaction (pinch step, zoom button, or HUD
    /// tap). The display link fades the HUD once this is older than
    /// `zoomOverlayVisibleDuration`. Time-based off the per-frame callback, not
    /// a sleeping timer task, so it honors the no-sleep rule and tracks real
    /// elapsed time regardless of frame rate.
    private var zoomOverlayLastInteraction: CFTimeInterval = 0
    private static let zoomOverlayVisibleDuration: CFTimeInterval = 2.5
    /// Persisted user "default zoom" backing the zoom-control overlay's
    /// reset/save/restore actions. Owned by the surface (constructed at init)
    /// rather than reached through a singleton, so it is injectable in tests.
    private let zoomPreference = MobileTerminalZoomPreference()
    var bridge = GhosttySurfaceBridge()
    /// Enables both terminal artifact taps and the coalesced visible-frame count.
    public var artifactFilesEnabled: Bool {
        get { inputProxy.artifactFilesEnabled }
        set {
            let changed = inputProxy.artifactFilesEnabled != newValue
            inputProxy.artifactFilesEnabled = newValue
            guard changed else { return }
            resetVisibleArtifactCountTracking()
        }
    }
    var onFocusInputRequestedForTesting: (() -> Void)?
    private var surfaceTitle: String?
    var displayLink: CADisplayLink?
    private var cursorRenderWakeState = TerminalCursorRenderWakeState()
    /// Immutable last-verified pixels retained above an in-progress replay.
    var verifiedReplayFrozenPresentationLayer: CALayer?
    var verifiedReplayFrozenBackgroundLayer: CALayer?
    var verifiedReplayFrozenContentLayer: CALayer?
    var verifiedReplayFrozenImage: CGImage?
    var verifiedReplayFrozenTransactionID: UInt64?
    var verifiedReplayFrozenViewportRect: CGRect?
    var verifiedReplayGeometryRevision: UInt64 = 0
    var verifiedReplayReadyFence: VerifiedReplayPresentationFence?
    var verifiedReplayReadyTransactionID: UInt64?
    /// Set before the pre-freeze drain submission and kept set until an exact
    /// replay presentation is revealed or the surface is torn down.
    var verifiedReplayRenderSuppressed = false
    var needsDraw: Bool = false
    /// Countdown of extra draw requests after a geometry change, so the
    /// renderer (which presents a frame behind) produces a frame at the final
    /// settled layer size rather than leaving a stale mid-animation surface.
    /// Bounded to avoid a perpetual main-queue present flood.
    private var pendingRenderFrames: Int = 0
    /// At most one tokened render is in flight on `outputQueue` at a time. The
    /// display link can fire at 120Hz and previously enqueued a render every
    /// frame with no guard, so during a continuous pinch renders piled up
    /// faster than the serial queue drained them. Each op stayed fast, but the
    /// DISPLAYED frame fell seconds behind the live font and only caught up
    /// when zoom stopped and the backlog drained — the "frozen, no updates"
    /// symptom. Coalescing caps the backlog: while a render is in flight, mark
    /// `needsAnotherRender` and re-enqueue exactly one after the platform layer
    /// acknowledges the current frame.
    var renderInFlight: Bool = false
    var renderInFlightSince: CFTimeInterval?
    var needsAnotherRender: Bool = false
    /// Retry count carried into the one follow-up ordinary submission after a
    /// renderer failure. Keeping it outside the new token prevents the
    /// follow-up request from silently resetting the failure episode to zero.
    var pendingRenderRetryCount: UInt8 = 0
    /// Geometry invalidation may replace a token only once while that
    /// replacement is still queued on `outputQueue`. Later size changes mark
    /// another frame instead of enqueueing another overlapping replacement.
    var renderReplacementInFlight = false
    /// The one frame currently allowed to reach the renderer. The callback is
    /// delivered only after Ghostty assigns the matching IOSurface, so output,
    /// local scrolling, geometry, and verified replay share one barrier.
    typealias RenderSubmissionKind = TerminalRenderSubmissionKind
    private static let maximumRenderPresentationRetries: UInt8 = 3
    /// Value-only render metadata captured by the serial surface queue.
    ///
    /// This type is explicitly nonisolated because its instances cross from
    /// the main-actor admission path into `GhosttySurfaceWorkQueue.async`.
    /// The raw surface pointer is valid for the matching generation, and the
    /// owning view resets that generation before teardown; no UIKit state is
    /// accessed from the queue closure.
    nonisolated struct RenderSubmission: @unchecked Sendable {
        let token: UInt64
        let generation: UInt64
        let kind: RenderSubmissionKind
        let surface: ghostty_surface_t
        let verifiedReplayRead: VerifiedReplaySurfaceRead?
        let presentationRetryCount: UInt8

        var ticket: TerminalRenderSubmission {
            TerminalRenderSubmission(token: token, generation: generation, kind: kind)
        }

        func withPresentationRetryCount(_ count: UInt8) -> RenderSubmission {
            RenderSubmission(
                token: token,
                generation: generation,
                kind: kind,
                surface: surface,
                verifiedReplayRead: verifiedReplayRead,
                presentationRetryCount: count
            )
        }
    }
    var renderPresentationGate = TerminalRenderPresentationGate()
    var renderSubmission: RenderSubmission?
    var pendingRenderSubmission: RenderSubmission?
    /// Set once output has changed the local model. The fallback remains visible
    /// until a tokened frame carrying that model is actually presented.
    var hasAppliedOutput = false
    private let surfaceFreeDrainWatchdog = SurfaceFreeDrainWatchdog()
    /// True while the app is inactive/backgrounded. On iOS `render_now`
    /// produces a frame synchronously on `outputQueue` and acquires a
    /// swap-chain frame slot from libghostty; if the app is backgrounded while
    /// the GPU can't complete a committed frame, that acquire could stall and
    /// the serial `outputQueue` would stop draining (queued `process_output`
    /// never runs). libghostty now bounds the acquire (generic.zig
    /// `frame_acquire_timeout_ns`) so a foreground stall self-heals as a
    /// skipped frame, but we still suspend on `willResignActive` — while the
    /// GPU is available so any in-flight render drains — and gate dispatch so
    /// no `render_now` is sent into the background.
    private var renderingSuspended: Bool = false
    var isRenderingSuspendedForVerifiedReplay: Bool { renderingSuspended }
    #if DEBUG
    /// Last time the display-link heartbeat logged (DEBUG diagnostic). The
    /// per-frame callback runs on the main thread, so a steady heartbeat proves
    /// main is alive; if it stops while the screen looks frozen, the main
    /// thread wedged (vs. an idle terminal or a stuck letterbox pin, where the
    /// heartbeat keeps ticking). Distinguishes the three on the next dogfood.
    private var lastHeartbeatTime: CFTimeInterval = 0
    /// Time of the most recent applied render-grid output, for the heartbeat's
    /// `sinceOutput` field (ties an idle blank to a stream gap).
    private var lastOutputAppliedTime: CFTimeInterval = 0
    #endif
    /// Set by any geometry trigger (resize/zoom/keyboard/effective-grid pin);
    /// the display link applies geometry at most once per frame. Coalescing
    /// prevents the fast-zoom geometry storm that thrashed the grid (jumbled
    /// rendering) and saturated the renderer.
    private var needsGeometrySync: Bool = false
    private var pendingGeometryReassert: Bool = false
    /// Last content scale pushed to libghostty; used to skip redundant
    /// per-frame `set_content_scale` pushes (the screen scale is constant).
    var lastAppliedContentScale: CGFloat = 0
    var surfaceHasReceivedOutput: Bool = false
    private var shouldScrollInitialOutputToBottom = true
    /// Serial background queue for `ghostty_surface_process_output`, which
    /// blocks on libghostty's internal renderer/IO futex. Running it on the
    /// main thread hangs the app until the scene-update watchdog kills it.
    /// Internal (not private) so the copyable-text extension in
    /// `GhosttySurfaceCopyableText.swift` can enqueue its surface read with
    /// the same FIFO-before-dispose ordering discipline.
    var outputQueue = GhosttySurfaceWorkQueue(generation: 0)
    var outputQueueGeneration: UInt64 = 0
    var pendingSurfaceFreeCount = 0
    var renderPipelineRecoveryPaused = false
    var renderPipelineRecoveryResumeTimer: (any DispatchSourceTimer)?
    var renderPipelineRecoveryPausedAt: CFTimeInterval?
    var consecutiveOutputTimeoutRecoveries = 0
    var lastRecoveryPausedDropLogTime: CFTimeInterval = 0
    static let renderPipelineStallDeadline: CFTimeInterval = 2.0
    static let outputApplyTimeout: CFTimeInterval = 2.0
    static let maxOutputApplyTimeout: CFTimeInterval = 16.0
    static let renderPipelineRecoveryResumeInterval: TimeInterval = 5.0
    static let visibleSnapshotTimeout: CFTimeInterval = 0.6
    static let copyableTextTimeout: CFTimeInterval = 2.0
    /// A prompt reveal must not keep probing a permanently busy renderer on
    /// every display-link tick. Retries are short and bounded; a later user
    /// interaction starts a fresh attempt.
    static let maximumScrollToBottomRetries: UInt8 = 8
    static let scrollToBottomRetryBaseDelay: CFTimeInterval = 1.0 / 60.0
    static let scrollToBottomRetryMaximumDelay: CFTimeInterval = 0.25
    static let maxPendingSurfaceFrees = 4
    // Timer-forced recovery may leak wedged libghostty surfaces, but only up to this hard cap.
    static let maxForcedRecoveryPendingSurfaceFrees = 8
    var nextSurfaceOperationID: UInt64 = 0
    var pendingOutputApply: PendingSurfaceOperation?
    var pendingGeometryApply: PendingSurfaceOperation?
    /// The local scroll operation is not itself an awaited surface operation,
    /// but replay reveal may wait for its generation. Keep an explicit
    /// deadline so a wedged output queue cannot park that waiter forever.
    var localScrollApplyStartedAt: CFTimeInterval?
    var localScrollApplyToken: UInt64?
    /// Same deadline contract for the pixel-precise local scroll pump.
    var localPixelScrollApplyStartedAt: CFTimeInterval?
    var localPixelScrollApplyToken: UInt64?
    var pendingVisibleSnapshot: PendingVisibleSnapshot?
    var pendingVerifiedReplayViewportAnchorCapture: PendingVerifiedReplayViewportAnchorCapture?
    var pendingVerifiedReplayViewportAnchorRestore: PendingVerifiedReplayViewportAnchorRestore?
    var pendingCopyableTextRead: PendingCopyableTextRead?
    var pendingVerifiedReplayPresentation: PendingVerifiedReplayPresentation?
    /// Quiet-frame countdown for local visible-path detection. Output, geometry,
    /// and coalesced scroll events reset it; detection runs only after the same
    /// eight-frame settle threshold used by viewport reporting.
    var visibleArtifactCountSettleFrames: Int?
    /// Invalidates a visible-text result when newer output or scrolling lands
    /// while the off-main Ghostty snapshot read is in flight.
    var visibleArtifactSnapshotGeneration: UInt64 = 0
    var visibleArtifactCountTask: Task<Void, Never>?
    var lastVisibleArtifactSnapshotText: String?
    var lastVisibleArtifactSnapshotColumns: Int?
    var lastVisibleArtifactSnapshotGeneration: UInt64?
    var lastReportedVisibleArtifactCount = 0

    /// Current visible-snapshot generation used to reject stale artifact totals.
    public var visibleArtifactCountGeneration: UInt64 {
        visibleArtifactSnapshotGeneration
    }
    private var hasPendingSurfaceOperationDeadline: Bool {
        pendingOutputApply != nil || pendingGeometryApply != nil || pendingVisibleSnapshot != nil
            || pendingVerifiedReplayViewportAnchorCapture != nil
            || pendingVerifiedReplayViewportAnchorRestore != nil
            || pendingCopyableTextRead != nil || pendingVerifiedReplayPresentation != nil
            || localScrollApplyStartedAt != nil
            || localPixelScrollApplyStartedAt != nil
    }
    /// Viewport-restore gate. `interactionGeneration` records user intent
    /// bumped on the main actor, while `appliedInteractionGeneration` records
    /// what `outputQueue` has applied. Anchors use the applied value at snapshot
    /// time and remain restorable only while intent equals that label, so a
    /// gesture whose batch has not reached the queue voids the anchor. The lock
    /// is held only for field reads and writes, never across a Ghostty C call.
    /// The ticket revokes a timed-out restore whose queued block has not claimed it.
    nonisolated struct ViewportRestoreGate {
        var interactionGeneration: UInt64 = 0
        var appliedInteractionGeneration: UInt64 = 0
        /// Raw Ghostty scrollbar state is not user intent. Resize and replay
        /// can transiently leave the mirror above bottom, so an anchor is
        /// eligible only after a real touch-scroll interaction.
        var preservesUserViewportAnchor = false
        var activeRestoreTicket: UInt64?
    }
    nonisolated let viewportRestoreGate =
        OSAllocatedUnfairLock<ViewportRestoreGate>(initialState: .init())
    /// Pixel-scroll state shared with `outputQueue`. `remainderPx` is the
    /// best-effort fractional pixel carried between batches; batches write it
    /// on `outputQueue`, and bottom snaps / surface replacement reset it from
    /// the main actor. Same lock discipline as `viewportRestoreGate`: held
    /// only for field reads and writes, never across a Ghostty C call.
    nonisolated struct LocalPixelScrollState {
        /// Bumped by every clear (dock/typing snap, surface replacement,
        /// alt routing). Batches capture the epoch at pump time and only
        /// commit results while it still matches, so an in-flight batch
        /// cannot resurrect a held position that a snap just cleared.
        var epoch: UInt64 = 0
        var remainderPx: Double = 0
        var lastFallbackLogTime: CFTimeInterval = 0
        /// The last (row, remainder) the pixel pump applied. While a gesture
        /// is active this is the position AUTHORITY: batches rebase from it
        /// instead of the live viewport, so a verified-replay bottom-reset
        /// between batches is overwritten on the next frame instead of
        /// hijacking the gesture. Cleared on dock/typing snaps and surface
        /// replacement, where the live viewport becomes the truth again.
        /// `positionPx` is the exact (unrounded) content-space position so
        /// sub-pixel deltas accumulate across batches; `remainderPx` is the
        /// whole-pixel offset actually applied to Ghostty. `revision` guards
        /// the row space: the held anchor is only valid while it matches.
        var lastApplied: (row: UInt64, remainderPx: Double, positionPx: Double, revision: UInt64, total: UInt64)?
        /// Device pixels of scroll-top reveal: how far past scrollback-top
        /// the gesture has pulled, realized by the host sliding the
        /// bottom-pinned render back down to uncover the rows the keyboard-up
        /// presentation clips above the screen. Only ever nonzero while the
        /// grid sits at scrollback top; cleared everywhere `lastApplied` is,
        /// plus on every keyboard leg (the budget it was granted against
        /// changes with the keyboard).
        var topRevealPx: Double = 0
        #if DEBUG
        /// Rate-limits slow-batch perf log lines (scroll-hitch investigation).
        var lastPerfLogTime: CFTimeInterval = 0
        #endif

        /// Seeds the held position from a verified-replay viewport anchor so a
        /// gesture that begins while the replay presentation is frozen rebases
        /// from the pre-replay reading position (what the frozen pixels show)
        /// instead of the mid-replay or bottom-reset live viewport. Only an
        /// idle authority may be seeded: a live gesture's held position always
        /// wins, and an epoch bump (typing snap, surface replacement, alt
        /// routing) between the caller's epoch read and this write voids the
        /// seed.
        mutating func seedHeldPositionIfIdle(
            row: UInt64,
            positionPx: Double,
            revision: UInt64,
            total: UInt64,
            epoch: UInt64
        ) -> Bool {
            guard self.epoch == epoch, lastApplied == nil else { return false }
            remainderPx = 0
            lastApplied = (
                row: row,
                remainderPx: 0,
                positionPx: positionPx,
                revision: revision,
                total: total
            )
            return true
        }
    }
    nonisolated let localPixelScrollState =
        OSAllocatedUnfairLock<LocalPixelScrollState>(initialState: .init())
    #if DEBUG
    /// Last pixel-precise viewport position the pixel pump applied.
    var debugLastPixelScroll: (row: UInt64, remainderPx: Double, positionPx: Double, revision: UInt64, total: UInt64)? {
        localPixelScrollState.withLock { $0.lastApplied }
    }
    #endif
    var userViewportInteractionGeneration: UInt64 {
        viewportRestoreGate.withLock { $0.interactionGeneration }
    }
    var preservesUserViewportAnchor: Bool {
        viewportRestoreGate.withLock { $0.preservesUserViewportAnchor }
    }
    @discardableResult
    func recordUserViewportScrollInteraction() -> UInt64 {
        let generation = viewportRestoreGate.withLock {
            $0.interactionGeneration &+= 1
            $0.preservesUserViewportAnchor = true
            return $0.interactionGeneration
        }
        // A queued prompt reveal is valid only until the next user gesture.
        // Invalidate it before the local scroll is admitted to the serial
        // surface queue, so a stale try-only completion cannot retry after
        // the user deliberately moves above live output.
        scrollToBottomRequested = false
        scrollToBottomRetryCount = 0
        scrollToBottomRetryAt = nil
        scrollToBottomInteractionGeneration = nil
        return generation
    }
    @discardableResult
    func recordFollowBottomInteraction() -> UInt64 {
        viewportRestoreGate.withLock {
            $0.interactionGeneration &+= 1
            $0.preservesUserViewportAnchor = false
            return $0.interactionGeneration
        }
    }
    private static let scrollMechanicsContentHeight: CGFloat = 1_000_000
    private var scrollMechanicsIsRecentering = false
    private var lastScrollMechanicsOffsetY: CGFloat?
    private var lastScrollMechanicsTouchPoint: CGPoint = .zero
    private lazy var scrollMechanicsView: UIScrollView = {
        let view = UIScrollView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.alwaysBounceVertical = true
        view.alwaysBounceHorizontal = false
        view.bounces = true
        view.decelerationRate = .normal
        view.delaysContentTouches = false
        view.canCancelContentTouches = true
        view.scrollsToTop = false
        view.contentInsetAdjustmentBehavior = .never
        view.panGestureRecognizer.cancelsTouchesInView = false
        view.delegate = self
        return view
    }()
    /// Whether a scroll gesture or its deceleration currently owns the
    /// scroll mechanics view. Runtime seam: the local pixel-scroll path uses
    /// it to hold position through replays mid-gesture, so it must compile in
    /// every configuration, not just DEBUG.
    var scrollInteractionActive: Bool {
        scrollMechanicsView.isTracking
            || scrollMechanicsView.isDragging
            || scrollMechanicsView.isDecelerating
    }
    #if DEBUG
    private var lastInputTimestamp: CFTimeInterval = 0
    private var latencySamples: [Double] = []
    var onOutputProcessedForTesting: (() -> Void)?
    /// DEBUG/UI-test accessibility carrier for the rendered terminal text.
    ///
    /// The surface itself must NOT be an accessibility leaf: a leaf hides its
    /// subviews from the accessibility tree, which made the docked accessory
    /// toolbar's zoom buttons (`terminal.inputAccessory.zoomOut/In`)
    /// unreachable to XCUITest. Instead this non-interactive, full-bounds child
    /// carries the `MobileTerminalSurface` identifier and the rendered-text
    /// label, leaving the toolbar (a sibling subview) individually accessible.
    private lazy var debugAccessibilityProxy: UIView = {
        let proxy = UIView()
        proxy.backgroundColor = .clear
        proxy.isUserInteractionEnabled = false
        proxy.isAccessibilityElement = true
        proxy.accessibilityIdentifier = "MobileTerminalSurface"
        return proxy
    }()

    /// DEBUG/UI-test accessibility carrier for the surface's live bottom-dock state.
    ///
    /// Exposes the four dock bits the round-9 reducer turns on
    /// (``ComposerDockState``) plus the last resolved ``ComposerDockIntent`` and the
    /// terminal proxy's first-responder status as a stable, parseable
    /// `accessibilityValue` string so an XCUITest can assert the surface's internal
    /// composer state precisely across repeated open/close cycles — the discriminating
    /// seam for the "composer jank" repro. Non-interactive, off-screen (1×1 at the
    /// origin) so it never intercepts taps or perturbs layout; it carries no rendered
    /// text (that stays on ``debugAccessibilityProxy``).
    ///
    /// The value is computed live on every accessibility READ (not cached on a
    /// transition), because `fieldFocused`/`proxyFirstResponder` flip a runloop after
    /// the synchronous transition (the focus token / `@FocusState` are deferred). An
    /// XCUITest predicate-wait re-reads the element until it converges, so a live getter
    /// is the only thing that lets the test see the SETTLED post-transition state.
    private lazy var composerDockProbe: ComposerDockProbeView = {
        let probe = ComposerDockProbeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        probe.backgroundColor = .clear
        probe.isUserInteractionEnabled = false
        probe.isAccessibilityElement = true
        probe.accessibilityIdentifier = "MobileComposerDockProbe"
        probe.surface = self
        return probe
    }()

    /// The last ``ComposerDockIntent`` ``handleComposerButtonTap()`` resolved, recorded
    /// purely so the dock probe can report it to the UI test. `nil` until the first
    /// compose-button tap.
    fileprivate var lastComposerDockIntent: ComposerDockIntent?

    var debugLastScrollbar: (total: Int, offset: Int, len: Int)?
    var debugBottomScrollStressPhase = "idle"
    var debugBottomViewportMismatchObserved = false
    /// Frame counter + one-shot latch for the scripted headless scroll
    /// (`Debug/GhosttySurfaceView+ScrollScriptDebug.swift`).
    var debugScrollScriptFrame = 0
    /// Scroll-smoothness audit: aggregates display-link cadence while a scroll
    /// gesture or its deceleration is active, logging one summary per second.
    struct DebugScrollFrameRateStats {
        var windowStart: CFTimeInterval = 0
        var lastTick: CFTimeInterval = 0
        var ticks = 0
        var missed = 0
        var maxGapMs: Double = 0
        var loggedDisplayInfo = false
    }
    var debugScrollFrameRateStats = DebugScrollFrameRateStats()
    var debugScrollScriptDone = false

    /// The live `key=value;…` description of the bottom dock, read by
    /// ``ComposerDockProbeView`` on every accessibility query. `fieldFocused` is the
    /// SAME ``composerFieldIsFirstResponder`` walk the reducer reads, so the probe and
    /// the real decision can never disagree.
    var composerDockProbeValue: String {
        let intent: String
        switch lastComposerDockIntent {
        case .openComposer: intent = "open"
        case .revealAndFocusComposer: intent = "reveal"
        case .closeComposer: intent = "close"
        case nil: intent = "none"
        }
        // Toolbar horizontal geometry, to localize the hide→reveal "compose button
        // off-screen" jank. `surfaceMinXInWindow` is exactly what
        // `accessoryLayoutInsetsProvider` feeds into the toolbar's leading inset; if it
        // is wrong during a reveal reflow the button row shifts. `toolbarOriginX` is the
        // docked container's own X (set to 0 by `layoutBottomDock`), so a nonzero value
        // here, or a large `surfaceMinXInWindow`, points at the displacement source.
        let surfaceMinXInWindow = window.map { Int(convert(bounds, to: $0).minX) } ?? -1
        let toolbarOriginX = dockedToolbar.map { Int($0.frame.minX) } ?? -1
        let requestedInputOwner = switch inputSession.state.requestedOwner {
        case .terminal: "terminal"
        case .composer: "composer"
        case nil: "none"
        }
        let actualInputOwner = switch inputSession.state.actualOwner {
        case .terminal: "terminal"
        case .composer: "composer"
        case nil: "none"
        }
        let inputScene = switch inputSession.state.scenePhase {
        case .active: "active"
        case .inactive: "inactive"
        }
        let inputModal = switch inputSession.state.modalPhase {
        case .none: "none"
        case .willPresent: "willPresent"
        case .presented: "presented"
        }
        let pointValue: (CGFloat) -> String = {
            String(format: "%.3f", Double($0))
        }
        let toolbarFrame = dockedToolbarFrameInSurface
        let composerFrame = composerContainer.convert(composerContainer.bounds, to: self)
        let toolbarMinY = toolbarFrame.map { pointValue($0.minY) } ?? "none"
        let toolbarMaxY = toolbarFrame.map { pointValue($0.maxY) } ?? "none"
        let internalPresentationGap = pointValue(currentInternalDockPresentationGap)
        let maximumInternalPresentationGap = pointValue(maximumInternalDockPresentationGap)
        let host = bottomDockHostView as? GhosttySurfaceHostView
        // The grid no longer resizes with the keyboard, so there is no
        // renderer-frozen "transition window": the ID is a constant. The key
        // stays for probe-format stability.
        let keyboardTransitionID = -1
        let keyboardTransitionTarget = pointValue(keyboardHeight)
        // Dock bottom edge (the keyboard's top edge when up) in SURFACE
        // coordinates — the same basis as the composer/toolbar frames above.
        // The host slides the surface during keyboard motion, so host
        // coordinates would drift from those frames by the slide amount.
        let dockBottomInSurface = bottomDockContainer.superview != nil
            ? bottomDockContainer.convert(bottomDockContainer.bounds, to: self).maxY
            : bounds.maxY
        let keyboardDockTargetTop = pointValue(dockBottomInSurface)
        let keyboardSlack = pointValue(host?.debugKeyboardAbsorptionSlack ?? 0)
        let keyboardTopReveal = pointValue(hostedScrollTopReveal)
        let keyboardDockSource = host?.debugUsesNotificationKeyboardDock == true
            ? "notification"
            : "layoutGuide"
        let terminalDockPresentationGap = pointValue(
            host?.debugTerminalDockPresentationGap ?? 0
        )
        let maximumTerminalDockPresentationGap = pointValue(
            host?.debugMaximumTerminalDockPresentationGap ?? 0
        )
        return [
            "chromeHidden=\(chromeHidden ? 1 : 0)",
            "composerActive=\(composerActive ? 1 : 0)",
            "fieldFocused=\(composerFieldIsFirstResponder ? 1 : 0)",
            "keyboardUp=\(keyboardVisible ? 1 : 0)",
            "proxyFirstResponder=\(inputProxy.isFirstResponder ? 1 : 0)",
            "inputRequested=\(requestedInputOwner)",
            "inputActual=\(actualInputOwner)",
            "inputScene=\(inputScene)",
            "inputModal=\(inputModal)",
            "keyboardHeight=\(pointValue(keyboardHeight))",
            "composerMinY=\(pointValue(composerFrame.minY))",
            "composerMaxY=\(pointValue(composerFrame.maxY))",
            "toolbarMinY=\(toolbarMinY)",
            "toolbarMaxY=\(toolbarMaxY)",
            "dockInternalPresentationGap=\(internalPresentationGap)",
            "dockMaxInternalPresentationGap=\(maximumInternalPresentationGap)",
            "terminalDockPresentationGap=\(terminalDockPresentationGap)",
            "terminalDockMaxPresentationGap=\(maximumTerminalDockPresentationGap)",
            "keyboardSlack=\(keyboardSlack)",
            "keyboardTopReveal=\(keyboardTopReveal)",
            "dockSeamPadding=\(pointValue(hostedDockSeamPadding))",
            "screenScale=\(pointValue(preferredScreenScale))",
            "bottomSafeArea=\(pointValue(safeAreaInsetsBottom))",
            "keyboardGuideTop=\(keyboardDockTargetTop)",
            "keyboardDockSource=\(keyboardDockSource)",
            "keyboardSeatWillOnly=\(host?.debugSeatTrustsOnlyWillFrames == true ? 1 : 0)",
            "keyboardDockTargetTop=\(keyboardDockTargetTop)",
            "keyboardTransitionID=\(keyboardTransitionID)",
            "keyboardTransitionTarget=\(keyboardTransitionTarget)",
            "bandMounted=\(composerContainer.subviews.isEmpty ? 0 : 1)",
            "toolbarVisible=\(dockedToolbar?.isHidden == false ? 1 : 0)",
            "surfaceMinXInWindow=\(surfaceMinXInWindow)",
            "toolbarOriginX=\(toolbarOriginX)",
            "lastIntent=\(intent)",
            "bottomStressPhase=\(debugBottomScrollStressPhase)",
            "viewportHeight=\(Int(terminalViewportHeight))",
            "targetViewportHeight=\(Int(targetTerminalViewportHeight))",
            "renderMinY=\(Int(lastRenderRect.minY))",
            "renderMaxY=\(Int(lastRenderRect.maxY))",
            // Rendered terminal height vs the surface bounds, so a UI test can
            // assert the grid returns to (near) full height once the keyboard is
            // down: the "terminal not full height when keyboard closed" guard. The
            // grid floors to whole cells so it is a few points under bounds even at
            // full height; the test compares the gap, not equality.
            "renderHeight=\(Int(lastRenderRect.height))",
            "boundsHeight=\(Int(bounds.height))",
            "scrollTotal=\(debugLastScrollbar?.total ?? -1)", "scrollOffset=\(debugLastScrollbar?.offset ?? -1)",
            "scrollLen=\(debugLastScrollbar?.len ?? -1)", "scrollAtBottom=\(debugScrollbarAtBottomForTesting ? 1 : 0)",
            "staleViewportObserved=\(debugBottomViewportMismatchObserved ? 1 : 0)",
            inputProxy.accessoryLayoutDiagnostics,
        ].joined(separator: ";")
    }

    private var debugScrollbarAtBottomForTesting: Bool {
        guard let snapshot = debugLastScrollbar else { return false }
        return snapshot.total > snapshot.len && snapshot.offset >= max(0, snapshot.total - snapshot.len - 1)
    }
    #endif
    private let snapshotFallbackView: UITextView = {
        let view = UITextView()
        view.backgroundColor = UIColor(red: 0x27/255.0, green: 0x28/255.0, blue: 0x22/255.0, alpha: 1)
        view.textColor = UIColor(red: 0xfd/255.0, green: 0xff/255.0, blue: 0xf1/255.0, alpha: 1)
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        view.textContainer.lineFragmentPadding = 0
        view.isEditable = false
        view.isSelectable = false
        view.isScrollEnabled = true
        view.isUserInteractionEnabled = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.isHidden = true
        return view
    }()

    var surface: ghostty_surface_t?
    var surfaceGeneration: UInt64 = 0
    #if DEBUG
    var latencyLastAppliedSequence: UInt64?
    #endif
    private var lastReportedSize: TerminalGridSize?
    /// Latest natural grid awaiting a debounced report to the Mac. The display
    /// link sends it only after the grid has held steady for
    /// `viewportReportSettleThreshold` frames. Reporting every intermediate
    /// size during the attach / keyboard / zoom settle resized the Mac PTY
    /// repeatedly, so the shell redrew its prompt on each SIGWINCH and the
    /// initial scrollback filled with the prompt duplicated at every width.
    private var pendingViewportReport: TerminalGridSize?
    private var viewportReportSettleFrames = 0
    /// Widest container this surface has actually rendered in the current
    /// window geometry. A phone split-view sidebar is an overlay, but UIKit can
    /// briefly size the detail view as a split column while it transitions.
    var widestRenderedContainerWidth: CGFloat = 0
    var reportWidthWindowSize: CGSize = .zero
    /// Bounded retries for the viewport report round-trip. The report goes to
    /// the Mac, which echoes back the effective grid via `applyViewSize`. If the
    /// round-trip yields no effective grid (RPC timeout / lost reply), the
    /// render stays pinned to the prior `effectiveGrid` and looks frozen even
    /// though the main thread is fine. On a no-effective result we re-arm the
    /// report (display-link driven, no timers) up to `maxViewportReportRetries`
    /// so a transient drop self-heals; a confirmed result resets the count.
    private var viewportReportRetries = 0
    private static let maxViewportReportRetries = 3
    /// Monotonic stamp for each natural-grid report handed to the delegate.
    /// `applyConfirmedViewSize(cols:rows:reportID:)` applies an echo only when
    /// its ID is still the newest, so an out-of-order RPC reply for an older
    /// (e.g. keyboard-up) report cannot re-pin a grid the surface outgrew —
    /// the natural grid would be unchanged afterwards, nothing would ever
    /// re-report, and the letterbox gap above the terminal would be permanent.
    private var viewportReportID: UInt64 = 0
    /// True from the moment a natural-grid report is handed to the delegate
    /// until the daemon's round-trip resolves for the NEWEST report (echo
    /// confirmed, or the bounded retries are exhausted). While set, the
    /// viewport layout treats the negotiation as unsettled (see
    /// `viewportSnapshot()`): `effectiveGrid` is about to be superseded by
    /// the grant answering this report, so layout decisions must not treat
    /// the outgoing value as final.
    private var awaitingViewportEcho = false
    /// Frames of "no zoom in progress" required before the natural grid is
    /// reported to the Mac. Active zoom is already gated separately
    /// (`zoomSettleFrames != nil` holds the report during a pinch), so this is
    /// purely the post-settle latency for discrete resizes (keyboard show/hide,
    /// rotation, toolbar). The natural grid changes once per such event (not per
    /// animation frame), so a short settle still coalesces a burst without
    /// adding the old ~0.5s tail before the Mac reflows and re-sends. ~0.07s at
    /// 120Hz / 0.13s at 60Hz.
    private static let viewportReportSettleThreshold = 8
    private var lastSnapshotFallbackHTML: String?
    /// Daemon-authoritative grid used for modes that need exact remote-cell
    /// replay. When nil, the surface fills the phone's natural capacity.
    var effectiveGrid: (cols: Int, rows: Int)?
    /// Cached cell metrics derived from the most recent
    /// `ghostty_surface_size` measurement. Used to translate an effective
    /// cols×rows pin into a pixel box without re-round-tripping through
    /// Ghostty. Zero until the first layout has measured.
    var cellPixelSize: CGSize = .zero
    /// 1 px separator stroke drawn around the pinned surface rect when the
    /// container is larger than the render target (i.e., this device is
    /// not the smallest). Added lazily on first letterbox.
    private var letterboxBorderLayer: CAShapeLayer?
    /// Last render rect used for the Ghostty surface inside the host view's
    /// coordinate space. Kept so the border layer can match it without a
    /// second set_size round-trip.
    var lastRenderRect: CGRect = .zero
    private var viewportCoordinator = TerminalViewportCoordinator()
    /// The bounds size the last layout-driven geometry sync ran for. Layout
    /// passes with unchanged bounds (host keyboard animation, sibling churn)
    /// must not re-enter `set_size`: every other geometry input (composer
    /// band, chrome, safe area, fonts) schedules its own sync at its
    /// mutation site, so bounds are the only layout-borne input.
    var lastLayoutGeometrySyncSize: CGSize = .zero
    private var bottomDockToKeyboardConstraint: NSLayoutConstraint?
    private var bottomDockHostConstraints: [NSLayoutConstraint] = []
    private weak var bottomDockHostView: UIView?
    private var composerHeightConstraint: NSLayoutConstraint?
    private var toolbarHeightConstraint: NSLayoutConstraint?
    #if DEBUG
    private var keyboardHeightOverrideForTesting: CGFloat?
    private var maximumInternalDockPresentationGap: CGFloat = 0
    #endif

    #if DEBUG
    struct DebugGeometrySnapshot {
        let boundsSize: CGSize
        let renderRect: CGRect
        let screenScale: CGFloat
        let reportedSize: TerminalGridSize?
        let renderedSize: TerminalGridSize?
        let isLetterboxBorderVisible: Bool
        let letterboxBorderPathBounds: CGRect?
        /// The viewport the terminal content may occupy right now (bounds minus
        /// the keyboard/safe-area + composer + toolbar reservation). The render
        /// rect is bottom-pinned inside this; any `renderRect.minY -
        /// viewportRect.minY` difference is user-visible empty space at the top.
        let viewportRect: CGRect
        /// The daemon-authoritative grid pin, nil when filling naturally.
        let effectiveGrid: (cols: Int, rows: Int)?
        /// Measured cell size in device pixels (zero before first measure).
        let cellPixelSize: CGSize
        let keyboardHeight: CGFloat
        /// The font actually rendering right now (may be auto-fit adjusted).
        let liveFontSize: Float32
        /// The user's explicit font choice that capacity reports are based on.
        let baseFontSize: Float32
    }

    func debugGeometrySnapshotForTesting() -> DebugGeometrySnapshot {
        let renderedSize: TerminalGridSize? = {
            guard let surface else { return nil }
            let size = ghostty_surface_size(surface)
            return TerminalGridSize(
                columns: Int(size.columns),
                rows: Int(size.rows),
                pixelWidth: Int(size.width_px),
                pixelHeight: Int(size.height_px)
            )
        }()
        return DebugGeometrySnapshot(
            boundsSize: bounds.size,
            renderRect: lastRenderRect,
            screenScale: preferredScreenScale,
            reportedSize: lastReportedSize,
            renderedSize: renderedSize,
            isLetterboxBorderVisible: letterboxBorderLayer?.isHidden == false,
            letterboxBorderPathBounds: letterboxBorderLayer?.path?.boundingBoxOfPath,
            viewportRect: terminalViewportRect,
            effectiveGrid: effectiveGrid,
            cellPixelSize: cellPixelSize,
            keyboardHeight: keyboardHeight,
            liveFontSize: liveFontSize,
            baseFontSize: userBaseFontSize
        )
    }

    func setKeyboardHeightForTesting(_ height: CGFloat) {
        setKeyboardHeightOverrideForTesting(height)
        layoutRenderedTerminalForCurrentViewport()
        layoutBottomDock()
        layoutBottomDockHierarchyIfNeeded()
        syncSurfaceGeometry(shouldReassertNaturalSize: true)
    }


    #endif

    /// Suppresses render dispatch while keeping the display link, geometry,
    /// and viewport reporting alive. Hosts where a Metal present can never
    /// complete (a scene-less xctest process) set this so a stalled present
    /// cannot trip the render-pipeline stall recovery and pause geometry;
    /// geometry (`set_size` + measure) never needs a present. Defaults false;
    /// no production caller flips it (tests reach it via `@testable import`).
    var isRenderDispatchSuppressed = false

    var currentGridSize: TerminalGridSize {
        lastReportedSize ?? TerminalGridSize(columns: 100, rows: 32, pixelWidth: 900, pixelHeight: 650)
    }

    /// Structured diagnostic log, property-injected from the shell store by
    /// ``GhosttySurfaceRepresentable`` so the composer-dock probes land in the
    /// blob the diagnostic export captures. The event payloads are bounded and
    /// privacy-safe, so the same sink is available in Release builds. `nil` in
    /// hosts that do not wire it; every probe is then a no-op.
    public var diagnosticLog: DiagnosticLog?

    private lazy var inputSession = TerminalInputSessionCoordinator(
        focus: { [weak self] owner in
            self?.performInputFocus(owner) ?? false
        },
        resign: { [weak self] owner in
            self?.performInputResign(owner) ?? true
        },
        actualOwnerDidChange: { [weak self] owner in
            self?.inputActualOwnerDidChange(owner)
        }
    )

    private lazy var inputProxy: TerminalInputTextView = {
        let inputProxy = TerminalInputTextView()
        inputProxy.terminalTheme = terminalTheme
        inputProxy.onFirstResponderChanged = { [weak self] isFirstResponder in
            self?.inputSession.send(
                .responderChanged(owner: .terminal, isFirstResponder: isFirstResponder)
            )
        }
        inputProxy.onText = { [weak self] text in
            guard let self else { return }
            self.handleUserProducedInput()
            #if DEBUG
            self.lastInputTimestamp = CACurrentMediaTime()
            #endif
            // Send all text directly to the transport as raw bytes.
            // Ghostty is display-only; the remote server handles echo.
            // Replace \n with \r (terminals expect CR for Return).
            let normalized = text.replacingOccurrences(of: "\n", with: "\r")
            let data = Data(normalized.utf8)
            TerminalInputDebugLog.log("surface.onText text=\(TerminalInputDebugLog.textSummary(text)) data=\(TerminalInputDebugLog.dataSummary(data))")
            self.delegate?.ghosttySurfaceView(self, didProduceInput: data)
        }
        inputProxy.onBackspace = { [weak self] in
            guard let self else { return }
            self.handleUserProducedInput()
            // Send DEL (0x7F) directly to transport as raw byte.
            let data = Data([0x7F])
            TerminalInputDebugLog.log("surface.onBackspace data=\(TerminalInputDebugLog.dataSummary(data))")
            self.delegate?.ghosttySurfaceView(self, didProduceInput: data)
        }
        inputProxy.onEscapeSequence = { [weak self] data in
            guard let self else { return }
            self.handleUserProducedInput()
            TerminalInputDebugLog.log("surface.onEscape data=\(TerminalInputDebugLog.dataSummary(data))")
            self.delegate?.ghosttySurfaceView(self, didProduceInput: data)
        }
        inputProxy.onPasteImage = { [weak self] data, format in
            guard let self else { return }
            self.handleUserProducedInput()
            TerminalInputDebugLog.log("surface.onPasteImage bytes=\(data.count) format=\(format)")
            self.delegate?.ghosttySurfaceView(self, didPasteImage: data, format: format)
        }
        inputProxy.onZoom = { [weak self] direction in
            self?.performFontZoom(direction)
        }
        inputProxy.onToolbarDiagnosticAction = { [weak self] action in
            guard let self else { return }
            self.delegate?.ghosttySurfaceView(self, didUseToolbarAction: action)
        }
        inputProxy.onToggleComposer = { [weak self] in
            guard let self else { return }
            self.handleComposerButtonTap()
        }
        inputProxy.onHideKeyboard = { [weak self] in
            guard let self else { return }
            self.delegate?.ghosttySurfaceView(self, didUseToolbarAction: .keyboardToggle)
            // The keyboard toggle is a low-frequency, privacy-safe lifecycle
            // edge. Keep it in Release diagnostics so a shared user log can
            // distinguish responder loss from an intentional keyboard close.
            if self.composerActive {
                let frOwner = TerminalInputTextView.responderIdentity(of: CurrentResponderProbe().current())
                self.diagnosticLog?.record(DiagnosticEvent(
                    .composerKeyboardToggleWhilePresented,
                    ms: UInt32(max(0, self.keyboardHeight)),
                    a: self.inputProxy.isFirstResponder ? 1 : 0,
                    b: frOwner.rawValue
                ))
            }
            // Round 8: the keyboard-toggle button only raises/lowers the keyboard. The
            // toolbar stays visible either way, and an open composer survives a
            // keyboard-down (its draft lives in the store; the field just loses focus).
            // Resign whichever responder actually owns the keyboard: with the composer
            // open by default the band can be presented (`composerActive == true`)
            // while the terminal's hidden input proxy holds first responder (a
            // terminal tap focuses the proxy without closing the band), and the proxy
            // is a sibling of `composerContainer`, so `endEditing` on the container
            // alone would resign nothing and the keyboard would stay up.
            if self.keyboardVisible {
                self.resignCurrentInput()
            } else {
                self.focusInput()
            }
        }
        inputProxy.onHideChrome = { [weak self] in
            guard let self else { return }
            self.delegate?.ghosttySurfaceView(self, didUseToolbarAction: .hideChrome)
            self.setChromeHidden(true)
        }
        inputProxy.onOpenToolbarSettings = { [weak self] in
            guard let self else { return }
            self.delegate?.ghosttySurfaceView(self, didUseToolbarAction: .customize)
            self.delegate?.ghosttySurfaceViewDidRequestToolbarSettings(self)
        }
        inputProxy.onOpenArtifactFiles = { [weak self] sourceView in
            guard let self else { return }
            self.delegate?.ghosttySurfaceView(self, didRequestArtifactFilesFrom: sourceView)
        }
        inputProxy.accessoryLayoutInsetsProvider = { [weak self] in
            guard let self,
                  let window = self.window else {
                return .zero
            }

            let terminalFrame = self.convert(self.bounds, to: window)
            return UIEdgeInsets(
                top: 0,
                left: max(0, terminalFrame.minX),
                bottom: 0,
                right: max(0, window.bounds.maxX - terminalFrame.maxX)
            )
        }
        return inputProxy
    }()

    /// Creates an embedded surface and applies its colors before the first frame.
    /// - Parameters:
    ///   - runtime: The process-wide embedded Ghostty runtime.
    ///   - delegate: The receiver for input and viewport changes.
    ///   - fontSize: Initial terminal font size in points.
    ///   - terminalTheme: Renderer-effective colors used by surrounding UIKit chrome.
    ///   - terminalConfigTheme: Raw Ghostty configuration defaults. Defaults to
    ///     `terminalTheme` for callers that do not mirror a remote surface.
    public init(runtime: GhosttyRuntime, delegate: GhosttySurfaceViewDelegate,
                fontSize: Float32 = 10, terminalTheme: TerminalTheme = .monokai,
                terminalConfigTheme: TerminalTheme? = nil) {
        self.runtime = runtime
        self.delegate = delegate
        self.fontSize = fontSize
        self.liveFontSize = fontSize
        self.userBaseFontSize = fontSize
        self.terminalTheme = terminalTheme.validatedOrDefault()
        self.terminalConfigTheme = (terminalConfigTheme ?? terminalTheme).validatedOrDefault()
        super.init(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        bridge.attach(to: self)
        // The local view background (the area behind/around the rendered cells,
        // and the letterbox fill) is sourced from the synced theme rather than a
        // hardcoded color, so a fresh mount already shows the Mac's background and
        // a later theme change can recolor it live. The effective theme stays
        // authoritative because raw config defaults can differ under reverse video.
        backgroundColor = terminalTheme.terminalBackgroundUIColor
        isOpaque = true
        clipsToBounds = true
        #if DEBUG
        // The surface is a container, not a leaf, so the docked toolbar's
        // buttons stay accessible. `debugAccessibilityProxy` carries the
        // `MobileTerminalSurface` identifier + rendered-text label instead.
        isAccessibilityElement = false
        #endif
        addSubview(snapshotFallbackView)
        addSubview(scrollMechanicsView)
        addSubview(inputProxy)
        #if DEBUG
        addSubview(debugAccessibilityProxy)
        addSubview(composerDockProbe)
        #endif
        installBottomDockContainer()
        installPersistentToolbar()
        installComposerContainer()
        installBottomDockConstraints()
        installArtifactChipContainer()
        initializeSurface()

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        // Suspend rendering on `willResignActive` (fires before
        // `didEnterBackground`, while the GPU is still usable) so an in-flight
        // `render_now` drains and no new one is dispatched into the background.
        // `didEnterBackground` repeats it idempotently as a backstop.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func handleAppWillResignActive() {
        inputSession.send(.sceneWillResignActive)
        suspendRendering()
    }

    @objc private func handleAppDidEnterBackground() {
        // Backstop: `willResignActive` already suspended, but guarantee the
        // surface is occluded before the GPU goes away.
        suspendRendering()
    }

    @objc private func handleAppDidBecomeActive() {
        resumeRendering()
        inputSession.send(.sceneDidBecomeActive)
        // The guide reflects the current keyboard even if this surface missed a
        // notification while inactive; force a layout read before the next render.
        setNeedsLayout()
    }

    @objc private func handleAppWillEnterForeground() {
        guard surface != nil, window != nil else { return }
        // The Mac drops this device's sticky viewport pin a few seconds after the
        // connection backgrounds, so on reconnect it reverts to its own (often
        // larger) size. `lastReportedSize` is unchanged, so nothing re-reports on
        // its own — clear it and force a geometry pass so the natural grid is
        // re-sent. The report is queued now and flushed once `didBecomeActive`
        // restarts the frame pump (which also reconnects the socket).
        lastReportedSize = nil
        setNeedsGeometrySync(reassertNaturalSize: true)
    }

    /// Pause the render loop while the app is inactive or backgrounded.
    ///
    /// Marks the surface occluded (so `render_now`'s `drawFrame` early-returns
    /// before reaching the synchronous GPU `waitUntilCompleted`), trips the
    /// dispatch gate, and stops the frame pump. Idempotent: called from both
    /// `willResignActive` and `didEnterBackground`.
    private func suspendRendering() {
        renderingSuspended = true
        skipPendingVisibleSnapshot()
        skipPendingCopyableTextRead()
        stopDisplayLink()
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, false)  // false = occluded; drawFrame skips
        setFocus(false)
    }

    /// Resume the render loop once the app is active again.
    ///
    /// A `render_now` in flight at suspend either drained (the GPU was still
    /// available before background) or never dispatched, and its main-thread
    /// completion may have been deferred while the queue was suspended — so clear
    /// the in-flight flag to guarantee the first foreground frame can dispatch,
    /// re-mark the surface visible, and restart the frame pump. Idempotent.
    private func resumeRendering() {
        renderingSuspended = false
        renderInFlight = false
        renderInFlightSince = nil
        renderReplacementInFlight = false
        needsAnotherRender = false
        pendingRenderRetryCount = 0
        renderPresentationGate.reset()
        renderSubmission = nil
        pendingRenderSubmission = nil
        guard let surface, window != nil else { return }
        ghostty_surface_set_occlusion(surface, true)  // true = visible
        setFocus(true)
        needsDraw = true
        startDisplayLink()
    }

    private var keyboardHeight: CGFloat = 0
    private var keyboardVisible = false
    /// Height the persistent bottom toolbar reserves in the terminal grid. The
    /// toolbar is constrained to ``UIView/keyboardLayoutGuide`` and the viewport
    /// coordinator consumes that same guide-derived overlap, so the grid must shrink
    /// by this much to keep the bottom TUI rows visible above it. Zero until the
    /// toolbar is installed (`installPersistentToolbar`).
    private var reservedToolbarHeight: CGFloat = 0
    /// Height of the docked accessory bar reserved in the grid geometry so the
    /// bottom TUI rows stay visible above it. Locked to the bar's actual button-row
    /// height (`TerminalInputTextView.dockedButtonRowHeight`) so the grid reserves
    /// EXACTLY the strip the buttons occupy — no taller. Round 3 reserved 44 while
    /// the strip was only 34, so the extra 10pt rendered as bar background below
    /// the buttons (the "gap below" Lawrence kept seeing). Matching them keeps the
    /// toolbar's live top edge equal to the viewport edge; any whole-cell render
    /// remainder stays inside the terminal viewport instead of becoming toolbar fill.
    private static let persistentToolbarHeight: CGFloat = TerminalInputTextView.dockedButtonRowHeight
    /// The single visual dock translated by the selected keyboard geometry source.
    /// The Shortcut and Composer bars are children of this view, so an interrupted
    /// animation cannot leave their presentation layers on different timelines.
    private let bottomDockContainer = UIView()
    /// The docked accessory bar. It is the upper child of ``bottomDockContainer``;
    /// the composer is the lower child nearest the keyboard.
    private weak var dockedToolbar: UIView?
    /// Whether the iMessage-style composer is currently open. The surface owns the
    /// whole bottom dock (terminal grid / toolbar / composer band / keyboard) in ONE
    /// coordinate system, so `composerActive` only drives the first-responder
    /// handover that keeps the keyboard up across the toggle. It deliberately does
    /// NOT gate the toolbar's visibility (the bar stays visible while composing) and
    /// does NOT alter the keyboard occupancy math: the composer band is reserved
    /// SEPARATELY (``composerBandHeight``) above the keyboard edge, never by
    /// reparenting the toolbar into a second layout system.
    private var composerActive = false
    /// The composer band: a surface-owned container the host installs the SwiftUI
    /// compose field into (via a `UIHostingController` in
    /// `GhosttySurfaceRepresentable`, which can see both layers; the terminal package
    /// cannot import the UI package). Auto Layout pins it directly to
    /// ``UIView/keyboardLayoutGuide`` (iMessage's field-nearest-keyboard layout), with
    /// the docked toolbar riding its top edge and the terminal grid above that. The
    /// viewport coordinator consumes the same guide overlap for the
    /// `terminal / toolbar / composer / keyboard` stack.
    private let composerContainer = UIView()
    /// Height (points) the open composer band reserves above the keyboard edge. Fed
    /// by the host from the hosted compose field's intrinsic content size
    /// (``setComposerBandHeight(_:animated:)``); 0 while the composer is closed. The
    /// grid reservation adds this so a field-grow pushes the toolbar and terminal
    /// above it upward while the band stays pinned to the keyboard — the keyboard
    /// itself never moves.
    private var composerBandHeight: CGFloat = 0
    /// Surface-owned host for the SwiftUI artifact chip. Keeping it beside the
    /// toolbar/composer containers makes keyboard and composer movement use one
    /// coordinate system instead of a competing SwiftUI safe-area offset.
    private let artifactChipHost = GhosttySurfaceArtifactChipHost()
    /// True once SwiftUI has dismantled the hosting representable for this
    /// surface. A dismantled surface performs no render, output, or
    /// accessibility work so a view SwiftUI has removed cannot keep driving the
    /// renderer or the accessibility tree.
    /// Internal for `GhosttySurfaceView+RenderRecovery.swift` recovery guards.
    var isDismantled = false
    /// Whether the hidden terminal input should become first responder when the
    /// surface attaches to a window. Set to `false` to suppress autofocus after
    /// chrome actions (create workspace/terminal, switch terminal) so the
    /// software keyboard does not pop up unprompted.
    public var autoFocusOnWindowAttach = true
    /// The shell-level surface/terminal id this view renders (the id the
    /// workspace store streams bytes for), stamped by the mounting
    /// representable. Scopes registry lookups — e.g. the "View as Text"
    /// capture — to the terminal the caller actually asked about, instead of
    /// whichever registered surface happens to sort first.
    public var hostSurfaceID: String?

    /// Folds the host-observed keyboard state into the model. Purely
    /// bookkeeping: the grid and render placement never consume the keyboard
    /// (the host translates the render wrapper instead), so no geometry
    /// negotiation is scheduled — `keyboardHeight` only seats the dock's
    /// bottom constraint and feeds diagnostics.
    ///
    /// - Parameters:
    ///   - height: The live keyboard overlap in points.
    ///   - isVisible: The keyboard visibility when the caller knows it
    ///     (notifications); `nil` for settled-seat self-heals (layout guide
    ///     reads), which must not fabricate a visibility transition.
    func setHostedKeyboardState(height: CGFloat, isVisible: Bool?) {
        if let isVisible, keyboardVisible != isVisible {
            #if DEBUG
            // The composer-up/keyboard-down desync can be reached WITHOUT the dismiss
            // button (code 24): a swipe-to-dismiss, an attached hardware keyboard, or
            // backgrounding all collapse the keyboard straight through this visible→false
            // transition. Codes 23/24 are silent on those paths, so the onset of the
            // desync — `keyboardVisible→false while the composer is still active` — is recorded
            // here too, with the resolved first-responder owner, so a Capture&Send trace
            // is complete no matter how the keyboard went down. Pure diagnostics; the hide
            // behavior below is unchanged.
            if keyboardVisible, !isVisible, composerActive {
                let frOwner = TerminalInputTextView.responderIdentity(of: CurrentResponderProbe().current())
                MobileDebugLog.anchormux(
                    "composer.keyboardHideWhilePresented prevKeyboardHeight=\(Int(keyboardHeight)) frOwner=\(frOwner.rawValue) proxyIsFR=\(inputProxy.isFirstResponder ? 1 : 0)"
                )
            }
            #endif
            keyboardVisible = isVisible
            inputProxy.setKeyboardShown(isVisible)
            // Round 8: the toolbar is ALWAYS visible and the composer band survives
            // a keyboard-down (its draft lives in the store; the field just loses
            // focus). The composer is dismissed only by its chevron or the toolbar
            // composer button.
            updateDockedToolbarVisibility()
        }
        let nextHeight = max(0, height)
        guard abs(nextHeight - keyboardHeight) > 0.25 else { return }
        MobileDebugLog.anchormux(
            "kb.model \(Int(keyboardHeight))->\(Int(nextHeight)) vis=\(isVisible.map { $0 ? "1" : "0" } ?? "-")"
        )
        keyboardHeight = nextHeight
        layoutBottomDock(using: viewportSnapshot())
    }

    func sampleHostedKeyboardPresentation() {
        let host = bottomDockHostView as? GhosttySurfaceHostView
        // Content written while the keyboard is up consumes the blank band;
        // the host re-derives the absorption slack so the render follows the
        // content bottom down to the composer bar (and back up after a
        // `clear`). Cheap: a single non-blocking cursor query per frame,
        // only while a keyboard is actually up.
        host?.refreshKeyboardAbsorptionIfNeeded()
        host?.sampleTerminalDockPresentationGap()
        #if DEBUG
        sampleInternalDockPresentationGap()
        #endif
    }

    private func installBottomDockContainer() {
        bottomDockContainer.backgroundColor = .clear
        bottomDockContainer.clipsToBounds = false
        bottomDockContainer.layer.zPosition = Self.bottomChromeZPosition
        addSubview(bottomDockContainer)
    }

    /// Pins one dock container to the selected keyboard geometry source. Keyboard
    /// motion translates one layer; child constraints arrange the bars internally.
    private func installBottomDockConstraints() {
        guard let dockedToolbar else { return }
        bottomDockContainer.translatesAutoresizingMaskIntoConstraints = false
        dockedToolbar.translatesAutoresizingMaskIntoConstraints = false
        composerContainer.translatesAutoresizingMaskIntoConstraints = false

        let dockBottom = bottomDockContainer.bottomAnchor.constraint(equalTo: bottomAnchor)
        dockBottom.constant = -keyboardOccupancyInBounds
        let composerHeight = composerContainer.heightAnchor.constraint(equalToConstant: 0)
        let toolbarHeight = dockedToolbar.heightAnchor.constraint(equalToConstant: 0)
        bottomDockToKeyboardConstraint = dockBottom
        composerHeightConstraint = composerHeight
        self.toolbarHeightConstraint = toolbarHeight

        let hostConstraints = [
            bottomDockContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomDockContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            dockBottom,
        ]
        bottomDockHostConstraints = hostConstraints
        bottomDockHostView = self

        NSLayoutConstraint.activate(hostConstraints + [
            dockedToolbar.topAnchor.constraint(equalTo: bottomDockContainer.topAnchor),
            dockedToolbar.leadingAnchor.constraint(equalTo: bottomDockContainer.leadingAnchor),
            dockedToolbar.trailingAnchor.constraint(equalTo: bottomDockContainer.trailingAnchor),
            dockedToolbar.bottomAnchor.constraint(equalTo: composerContainer.topAnchor),
            composerContainer.leadingAnchor.constraint(equalTo: bottomDockContainer.leadingAnchor),
            composerContainer.trailingAnchor.constraint(equalTo: bottomDockContainer.trailingAnchor),
            composerContainer.bottomAnchor.constraint(equalTo: bottomDockContainer.bottomAnchor),
            composerHeight,
            toolbarHeight,
        ])
        layoutBottomDock()
    }

    /// Moves the visual dock into the host that owns keyboard presentation.
    /// Returns the sole dock-bottom constraint for that host.
    func moveBottomDock(to host: UIView) -> NSLayoutConstraint {
        if host === bottomDockHostView, let bottomDockToKeyboardConstraint {
            return bottomDockToKeyboardConstraint
        }
        NSLayoutConstraint.deactivate(bottomDockHostConstraints)
        bottomDockContainer.removeFromSuperview()
        host.addSubview(bottomDockContainer)

        let dockBottom = bottomDockContainer.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        dockBottom.constant = -keyboardOccupancyInBounds
        let hostConstraints = [
            bottomDockContainer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bottomDockContainer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            dockBottom,
        ]
        bottomDockToKeyboardConstraint = dockBottom
        bottomDockHostConstraints = hostConstraints
        bottomDockHostView = host
        NSLayoutConstraint.activate(hostConstraints)
        host.setNeedsLayout()
        return dockBottom
    }

    var hostedBottomDockTopAnchor: NSLayoutYAxisAnchor {
        bottomDockContainer.topAnchor
    }

    var hostedBottomDockBottomAnchor: NSLayoutYAxisAnchor {
        bottomDockContainer.bottomAnchor
    }

    var hostedBottomDockFrame: CGRect {
        bottomDockContainer.frame
    }

    /// Strips keyboard-motion animations after a window detach so a reattach
    /// during a transition cannot resume a stale leg from the old window.
    func removeHostedBottomDockAnimations() {
        bottomDockContainer.layer.removeAllAnimations()
    }

    var hostedKeyboardHeight: CGFloat { keyboardHeight }

    var hostedChromeHidden: Bool { chromeHidden }

    /// Host-driven geometry resync for inputs the surface cannot observe
    /// itself: the grid container reads the WINDOW's bottom safe-area inset
    /// (the slid surface's own inset is a meaningless 0), and a window-level
    /// inset change does not fire this surface's `safeAreaInsetsDidChange`
    /// or change its bounds.
    func hostRequestsGeometrySync() {
        setNeedsGeometrySync()
    }

    /// True while the mirrored terminal is on the ALTERNATE screen (a
    /// full-screen TUI that owns the whole grid). Injected by the hosting
    /// representable from the shell store; the keyboard blank-space
    /// absorption is disabled then, because a TUI's cursor position says
    /// nothing about which rows are safe to cover.
    public var hostedAltScreenActive = false {
        didSet {
            guard hostedAltScreenActive != oldValue else { return }
            bottomDockHostView?.setNeedsLayout()
        }
    }

    /// Rows of the visible viewport that contain content, measured from the
    /// rendered screen text on the serial output queue (see `processOutput`).
    /// The cursor row alone is NOT a content proxy: apps like Claude Code
    /// draw UI rows BELOW the cursor (input-box border, shortcut hints), and
    /// covering them with the keyboard hid real content.
    var hostedContentBottomRowCount: Int?

    /// Points of blank render below the content bottom, or nil when it
    /// cannot be trusted (alternate screen, nothing measured yet, no render).
    /// Content bottom is the LOWER of the last non-blank screen row and the
    /// cursor row (the cursor can sit on a blank line below the last text).
    /// The host lets this blank band absorb the keyboard intrusion before
    /// the render slides: a mostly-empty screen stays top-pinned under the
    /// navigation bar and the keyboard covers only blank rows.
    var hostedBlankBelowContent: CGFloat? {
        guard !hostedAltScreenActive, !lastRenderRect.isEmpty else { return nil }
        let cellHeight = cellPixelSize.height / max(preferredScreenScale, 1)
        let rowsBottom: CGFloat? = hostedContentBottomRowCount.flatMap { rows in
            cellHeight > 0 ? CGFloat(rows) * cellHeight : nil
        }
        let cursorBottom = cursorBottomInRenderPoints()
        var contentBottom: CGFloat?
        switch (rowsBottom, cursorBottom) {
        case let (.some(rows), .some(cursor)): contentBottom = max(rows, cursor)
        case let (.some(rows), nil): contentBottom = rows
        case let (nil, .some(cursor)): contentBottom = cursor
        case (nil, nil): contentBottom = nil
        }
        guard let contentBottom else { return nil }
        return max(0, lastRenderRect.height - contentBottom)
    }

    /// Schedules an immediate off-main content-bottom measurement, bypassing
    /// the output-driven throttle, so a keyboard raise never computes its
    /// blank-space absorption from a stale row count (content written or
    /// cleared just before the raise, with no output since).
    func refreshHostedContentBottomNow() {
        guard let surface, !isDismantled else { return }
        let workQueue = outputQueue
        let generation = surfaceGeneration
        workQueue.queue.async { [weak self] in
            workQueue.lastContentBottomTime = CACurrentMediaTime()
            guard let viewportText = Self.surfaceText(surface, pointTag: GHOSTTY_POINT_VIEWPORT),
                  viewportText.utf8.count <= 131_072 else { return }
            let rows = Self.contentRowCount(inViewportText: viewportText)
            DispatchQueue.main.async {
                guard let self, self.surfaceGeneration == generation else { return }
                if rows != self.hostedContentBottomRowCount {
                    MobileDebugLog.anchormux(
                        "kb.contentRows \(self.hostedContentBottomRowCount.map(String.init) ?? "nil")->\(rows) at-raise"
                    )
                }
                self.hostedContentBottomRowCount = rows
            }
        }
    }

    /// The number of viewport rows up to and including the last row with any
    /// non-whitespace content. Pure text scan, safe off the main actor.
    nonisolated static func contentRowCount(inViewportText text: String) -> Int {
        var lastNonBlank = 0
        var row = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            row += 1
            if !line.allSatisfy(\.isWhitespace) {
                lastNonBlank = row
            }
        }
        return lastNonBlank
    }

    /// The cursor's bottom edge in render-local points (the coordinate space
    /// of `lastRenderRect.size`), or nil when not measurable. A non-blocking
    /// `ghostty_surface_ime_point` query; Ghostty remains the sole cursor
    /// renderer.
    private func cursorBottomInRenderPoints() -> CGFloat? {
        guard let surface else { return nil }
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        guard y > 0 else { return nil }
        return CGFloat(y)
    }

    /// The steady-state bottom chrome band in points: what
    /// `renderWrapper.bottom` must sit BELOW the dock top so the full-height
    /// render's bottom edge lands `hostedDockSeamPadding` above the dock top
    /// (composer bar) — the grid container reserves that seam, so this
    /// matches `bounds.height - layoutViewportRect.height - hostedDockSeamPadding`
    /// by construction and never contains the keyboard.
    var hostedBottomChromeReservation: CGFloat {
        chromeHidden
            ? 0
            : max(0, composerBandHeight) + reservedToolbarHeight + safeAreaInsetsBottom
    }

    /// The seam the grid container reserves above the dock while the chrome
    /// is visible: the render's bottom edge lands this many points above the
    /// dock top instead of flush against the toolbar.
    var hostedDockSeamPadding: CGFloat {
        chromeHidden ? 0 : TerminalLetterboxGeometry.dockSeamPadding
    }

    func hostedBottomReservation(
        keyboardHeight: CGFloat,
        bottomSafeAreaInset: CGFloat
    ) -> CGFloat {
        chromeHidden
            ? max(0, keyboardHeight)
            : TerminalLetterboxGeometry.keyboardOccupancy(
                keyboardHeight: keyboardHeight,
                bottomSafeAreaInset: bottomSafeAreaInset
            )
    }

    /// Points of scroll-top reveal the pixel-scroll axis has granted: how far
    /// the host slides the bottom-pinned render back down so the rows the
    /// keyboard-up presentation clips above the screen become visible. Read
    /// per frame by the host's content cap alongside the blank band.
    var hostedScrollTopReveal: CGFloat {
        CGFloat(localPixelScrollState.withLock { $0.topRevealPx }) / max(preferredScreenScale, 1)
    }

    /// The scroll-top reveal budget in points: how much of the full-height
    /// render the keyboard-up bottom-pin clips above the screen once the
    /// blank band's absorption is spent. Zero with the keyboard down. This is
    /// exactly how far the render may slide back down before it reaches its
    /// natural (keyboard-down) position, so a full reveal never over-rotates
    /// past the natural cap.
    var hostedScrollTopRevealBudget: CGFloat {
        let inset = safeAreaInsetsBottom
        let intrusion = hostedBottomReservation(
            keyboardHeight: keyboardHeight,
            bottomSafeAreaInset: inset
        ) - hostedBottomReservation(keyboardHeight: 0, bottomSafeAreaInset: inset)
        guard intrusion > 0 else { return 0 }
        return max(0, intrusion - (hostedBlankBelowContent ?? 0))
    }

    /// The reveal budget in device pixels, the pixel-scroll batch's unit
    /// (captured on the main actor at pump time, alongside the epoch).
    var hostedScrollTopRevealBudgetPx: Double {
        Double(hostedScrollTopRevealBudget * max(preferredScreenScale, 1))
    }

    /// Drops any granted reveal. Called on every keyboard leg: the budget
    /// the reveal was granted against changes with the keyboard, and a stale
    /// reveal on the next raise would cover the newest rows the user never
    /// scrolled away from.
    ///
    /// A nonzero reveal clears like every other pixel-authority clear, with
    /// an epoch bump, so a batch already in flight (whose captured budget
    /// predates this keyboard leg) cannot re-commit the cleared reveal after
    /// the leg seats the cap. Dropping the held anchor is free here: reveal
    /// is only ever granted at scrollback-top, where the anchor is
    /// (row 0, position 0) and the live viewport says the same thing. When
    /// no reveal is granted (the common keyboard toggle) this is a no-op so
    /// an active gesture's scroll authority is never perturbed.
    func clearHostedScrollTopReveal() {
        localPixelScrollState.withLock {
            guard $0.topRevealPx != 0 else { return }
            $0.epoch &+= 1
            $0.remainderPx = 0
            $0.lastApplied = nil
            $0.topRevealPx = 0
        }
    }

    func hostedTerminalPresentationBottom(in host: UIView) -> CGFloat? {
        let hostLayer = host.layer.presentation() ?? host.layer
        if let renderer = (layer.sublayers ?? []).first(where: isGhosttyRendererLayer) {
            let source = renderer.presentation() ?? renderer
            return source.convert(
                CGPoint(x: source.bounds.midX, y: source.bounds.maxY),
                to: hostLayer
            ).y
        }
        let source = layer.presentation() ?? layer
        return source.convert(
            CGPoint(
                x: bounds.midX,
                y: lastRenderRect.isEmpty ? terminalViewportRect.maxY : lastRenderRect.maxY
            ),
            to: hostLayer
        ).y
    }

    func hostedBottomDockPresentationTop(in host: UIView) -> CGFloat? {
        guard bottomDockContainer.superview != nil else { return nil }
        let source = bottomDockContainer.layer.presentation() ?? bottomDockContainer.layer
        let hostLayer = host.layer.presentation() ?? host.layer
        return source.convert(
            CGPoint(x: source.bounds.midX, y: source.bounds.minY),
            to: hostLayer
        ).y
    }

    #if DEBUG
    /// Switches the dock to a synthetic bottom anchor for host tests and previews.
    private func setKeyboardHeightOverrideForTesting(_ height: CGFloat) {
        let clamped = max(0, height)
        keyboardHeightOverrideForTesting = clamped
        keyboardHeight = clamped
        bottomDockToKeyboardConstraint?.constant = -TerminalLetterboxGeometry.keyboardOccupancy(
            keyboardHeight: clamped,
            bottomSafeAreaInset: safeAreaInsetsBottom
        )
    }
    #endif

    #if DEBUG
    /// Test seam: force a synthetic keyboard height so the keyboard-up layout
    /// (docked toolbar riding the keyboard edge, grid reserving toolbar +
    /// keyboard) can be screenshotted on the simulator, which refuses to render
    /// the software keyboard. Drives the exact same geometry path as a real
    /// keyboard. Used only by the terminal-layout preview harness.
    public func debugSetKeyboardHeightForLayoutPreview(_ height: CGFloat) {
        setKeyboardHeightOverrideForTesting(height)
        keyboardVisible = height > 0
        inputProxy.setKeyboardShown(keyboardVisible)
        // Mirror the live keyboard-tied visibility so the preview shows the bar
        // only when the synthetic keyboard is "up".
        updateDockedToolbarVisibility()
        layoutRenderedTerminalForCurrentViewport()
        layoutBottomDock()
        layoutBottomDockHierarchyIfNeeded()
        setNeedsGeometrySync()
        setNeedsLayout()
    }

    /// Test seam: present the zoom-control overlay (normally only shown on a
    /// pinch, which the simulator can't do) pinned visible so its appearance
    /// can be screenshotted.
    public func debugShowZoomControlOverlayForPreview() {
        showZoomOverlay()
        zoomOverlayLastInteraction = CACurrentMediaTime() + 3600
    }
    #endif

    /// Dock the accessory bar as a persistent bottom toolbar. Auto Layout pins it
    /// through the composer container to ``UIView/keyboardLayoutGuide``; the viewport
    /// coordinator consumes the same guide-derived overlap for the terminal grid.
    private func installPersistentToolbar() {
        let toolbar = inputProxy.toolbarView
        bottomDockContainer.addSubview(toolbar)
        dockedToolbar = toolbar
        // Raise the toolbar above the Ghostty renderer's own sublayer (which it
        // inserts directly into `self.layer`), so a dragged/lifted Liquid-Glass button
        // floating UP over the terminal is not occluded or clipped by the render layer
        // (item 6). Subview order alone does not guarantee this because the renderer
        // sublayer is composited at the layer level; the zoom overlay uses the same
        // `zPosition` lever. The toolbar must also not clip its own bounds so the lift
        // is visible above the strip.
        toolbar.layer.zPosition = Self.bottomChromeZPosition
        toolbar.clipsToBounds = false
        // The toggle glyph reflects the CURRENT model, not just future
        // transitions — a toolbar (re)installed mid-session must not lie
        // until the next keyboard event.
        inputProxy.setKeyboardShown(keyboardVisible)
        updateDockedToolbarVisibility()
    }

    /// Layer `zPosition` for the bottom chrome (toolbar + composer band), placing it
    /// above the Ghostty renderer's sublayer so a lifted Liquid-Glass button is not
    /// clipped by the terminal render bounds (item 6). Below the zoom HUD (1100).
    private static let bottomChromeZPosition: CGFloat = 1000
    /// Floats above dock chrome, terminal content, AND the verified-replay
    /// frozen presentation (zPosition 2000). The freeze copies only renderer
    /// pixels, so anything below it blinks out for the length of every
    /// freeze/reveal transaction — one ~40-90ms chip blink per output burst
    /// while an agent streams. Zoom-HUD conflicts are handled by the
    /// `zoomOverlayShown` visibility gate, not by z-order.
    private static let artifactChipZPosition: CGFloat = 2050

    /// Whether the always-visible bottom chrome (the docked accessory toolbar and,
    /// when open, the composer band) is currently on screen.
    ///
    /// Round 8 makes the toolbar ALWAYS visible — terminal mode, composer mode,
    /// keyboard up AND down — so the only thing that hides it is the explicit HIDE
    /// button (``chromeHidden``). When the
    /// keyboard is down the toolbar (and any open composer) ride above the bottom
    /// safe area through the keyboard guide's default fallback.
    private var dockedToolbarShouldBeVisible: Bool {
        !chromeHidden
    }

    /// True while the HIDE button has temporarily suppressed the bottom chrome
    /// (toolbar + composer band). The chrome reappears on the next tap of the
    /// terminal (``handleTap``). `isComposerPresented` is unchanged while hidden, so
    /// the composer (and its draft) reappear intact. Item 2 of the Round 8 spec.
    private var chromeHidden = false

    /// Bottom space (points) reserved below the toolbar for the keyboard OR the home
    /// indicator, whichever applies.
    ///
    /// When the software keyboard is up the toolbar rides its top, so this is the
    /// live keyboard height. When the keyboard is down the toolbar is still visible
    /// (Round 8), so it must clear the bottom safe area (home indicator) rather than
    /// sit flush on the screen edge — this returns ``safeAreaInsetsBottom`` then. The
    /// composer band and toolbar stack ABOVE this inset; the grid reserves it too.
    /// Used by the viewport coordinator and grid reservation.
    private var keyboardOccupancyInBounds: CGFloat {
        TerminalLetterboxGeometry.keyboardOccupancy(
            keyboardHeight: keyboardHeight,
            bottomSafeAreaInset: safeAreaInsetsBottom
        )
    }

    /// The current viewport the terminal content is allowed to occupy, after
    /// subtracting the keyboard/safe-area, composer band, and toolbar reservation.
    /// This is main-actor transition state, so it moves every keyboard animation
    /// frame instead of waiting for the async libghostty geometry readback.
    private var targetTerminalViewportHeight: CGFloat {
        viewportSnapshot().layoutViewportRect.height
    }

    private var terminalViewportHeight: CGFloat {
        viewportSnapshot().layoutViewportRect.height
    }

    var terminalViewportRect: CGRect {
        viewportSnapshot().layoutViewportRect
    }

    private func viewportSnapshot() -> TerminalViewportSnapshot {
        viewportCoordinator.snapshot(inputs: TerminalViewportInputs(
            bounds: bounds.size,
            keyboardHeight: keyboardHeight,
            composerBandHeight: composerBandHeight,
            reservedToolbarHeight: reservedToolbarHeight,
            toolbarFrameHeight: Self.persistentToolbarHeight,
            bottomSafeAreaInset: safeAreaInsetsBottom,
            chromeHidden: chromeHidden
        ))
    }

    private func layoutRenderedTerminalForCurrentViewport() {
        layoutRenderedTerminalForCurrentViewport(using: viewportSnapshot())
    }

    private func layoutRenderedTerminalForCurrentViewport(using snapshot: TerminalViewportSnapshot) {
        snapshotFallbackView.frame = snapshot.layoutViewportRect
        layoutVerifiedReplayFrozenPresentation(viewportRect: snapshot.layoutViewportRect)
        guard !lastRenderRect.isEmpty else { return }
        let renderRect = snapshot.renderRect(forRenderSize: lastRenderRect.size)
        guard renderRect != lastRenderRect else { return }
        MobileDebugLog.anchormux(
            "kb.renderRect \(Int(lastRenderRect.minY))->\(Int(renderRect.minY)) h=\(Int(renderRect.height))"
        )
        lastRenderRect = renderRect
        syncRendererLayerFrame(scale: preferredScreenScale, renderRect: renderRect)
        updateLetterboxBorder(
            renderRect: renderRect,
            isLetterboxed: snapshot.isLetterboxed(renderSize: renderRect.size)
        )
    }

    /// The bottom safe-area inset (home-indicator height) in this surface's bounds.
    ///
    /// The surface extends under the bottom safe area (the host applies
    /// `ignoresSafeArea(.container, .bottom)`), so when the keyboard is down the
    /// always-visible toolbar must clear this much to avoid the home indicator. Reads
    /// the view's own inset, falling back to the window's, because `safeAreaInsets`
    /// can be zero before the view is on a window.
    private var safeAreaInsetsBottom: CGFloat {
        TerminalLetterboxGeometry.resolvedBottomSafeAreaInset(
            viewInset: safeAreaInsets.bottom,
            windowInset: window?.safeAreaInsets.bottom ?? 0
        )
    }

    /// Reconcile the docked bar's visibility (and its reserved grid height) with
    /// the current keyboard + composer state. Hiding the bar releases its reserved
    /// height so the terminal grid reclaims that space; showing it reserves the
    /// height again. Idempotent: a no-op when already in the target state.
    private func updateDockedToolbarVisibility() {
        let shouldShow = dockedToolbarShouldBeVisible
        let reserved: CGFloat = shouldShow ? Self.persistentToolbarHeight : 0
        guard dockedToolbar?.isHidden != !shouldShow || reservedToolbarHeight != reserved else { return }
        dockedToolbar?.isHidden = !shouldShow
        // The composer band rides with the toolbar: hide it when the chrome is
        // suppressed, show it again when the chrome returns and a field is mounted.
        // Its height constraint already collapses to zero while hidden; toggling
        // `isHidden` also stops it intercepting taps.
        composerContainer.isHidden = !shouldShow || composerContainer.subviews.isEmpty
        reservedToolbarHeight = reserved
        layoutRenderedTerminalForCurrentViewport()
        updateArtifactChipVisibility(animated: true)
        setNeedsGeometrySync()
        setNeedsLayout()
    }

    /// Temporarily hide (or re-show) the bottom chrome — the always-visible toolbar
    /// and any open composer band — via the HIDE button (item 2).
    ///
    /// Hiding also drops the software keyboard: with the toolbar always visible, HIDE
    /// only makes sense as "clear all chrome to see the full terminal", which requires
    /// resigning the keyboard too. `isComposerPresented` is left untouched, so the
    /// composer (and its draft) reappear intact on the next terminal tap
    /// (``handleTap``). UIKit animates keyboard movement through its layout guide;
    /// ``animateBottomDock`` handles only the chrome-height change.
    /// Internal (not private) so behavior tests can drive the chrome-hidden
    /// dock seat via @testable import instead of a shipped test seam.
    func setChromeHidden(_ hidden: Bool) {
        guard chromeHidden != hidden else { return }
        chromeHidden = hidden
        if hidden, keyboardVisible {
            // Drop the keyboard first; its layout guide re-seats the dock while the
            // visibility update below removes the toolbar/composer. Resign
            // whichever responder actually owns the keyboard — the band can be
            // presented while the terminal's hidden input proxy (a sibling of
            // `composerContainer`) holds first responder, so gating on
            // `composerActive` alone would leave the keyboard up while the chrome
            // hides.
            resignCurrentInput()
        }
        updateDockedToolbarVisibility()
        if hidden {
            // Hide: animate the dock collapsing down into the bottom edge. (The toolbar
            // is set `isHidden` only after this animation by `updateDockedToolbarVisibility`
            // — actually `isHidden` is set synchronously, so this animate-out is largely
            // invisible, but it keeps the frame coherent for the next show.)
            animateBottomDock()
        } else {
            // Show: snap real frames into place with the bar visible, then let the
            // ``handleTap``-driven `focusInput()` → keyboard-show animation carry the
            // motion. Animating here from the collapsed bottom-edge strip would
            // double-animate against the keyboard rise.
            layoutBottomDock()
        }
        setNeedsGeometrySync()
    }

    /// Track whether the composer is open and keep the keyboard up across the
    /// draft↔normal toggle in BOTH directions.
    ///
    /// The surface owns the whole bottom dock (terminal grid / composer band /
    /// toolbar / keyboard) in one coordinate system; the toolbar is never reparented
    /// out, so it stays visible while composing and its buttons cannot disappear. The
    /// only job here is the first-responder handover that keeps the keyboard from
    /// dropping across the toggle:
    ///
    /// - Opening (`active == true`): deliberately do NOT resign the terminal input
    ///   proxy. The composer's hosted text field becomes first responder while this
    ///   keyboard is still up, so iOS hands the keyboard over in place. Resigning
    ///   first tore the keyboard down and the composer re-summoned it (a flicker).
    /// - Closing (`active == false`): two distinct intents share this path, told
    ///   apart by ``keyboardVisible``:
    ///   - Chevron-close while typing: `keyboardVisible == true`. The user wants to keep the
    ///     keyboard (a genuine return to the terminal). The composer's field resigns
    ///     first responder as it is torn out, with nothing to take it back, so re-take it
    ///     on the terminal input proxy in the same update — some responder is always
    ///     first responder at runloop end and the keyboard hands back in place instead of
    ///     dropping.
    ///   - Chevron-close while the keyboard is already down: `keyboardVisible == false` (a
    ///     legal Round 8 state — the composer survives a keyboard-down). Do NOT re-focus
    ///     the proxy; that would re-summon the keyboard the user already dismissed. The
    ///     toolbar stays visible regardless, so closing the composer just collapses its
    ///     band. Gating the re-focus on `keyboardVisible` makes both directions
    ///     correct.
    ///   No deferred timer task: the `become` is issued synchronously here.
    public func setComposerActive(_ active: Bool) {
        guard composerActive != active else { return }
        composerActive = active
        if active {
            // Opening: deliberately do NOT resign the terminal input proxy. The
            // composer's hosted text field becomes first responder while this
            // keyboard is still up, so iOS hands the keyboard over in place. The
            // toolbar stays a child of this surface throughout — it is never
            // reparented — so its buttons remain on screen. The composer band's
            // height arrives separately via `setComposerBandHeight(_:animated:)` once
            // the host mounts and measures the field.
        } else {
            // Closing: re-take first responder on the terminal input proxy ONLY when the
            // keyboard is still up (`keyboardVisible == true`, a chevron-close while typing) so
            // the keyboard hands back in place instead of dropping. When the keyboard is
            // already down (a legal Round 8 state — the composer survived a keyboard-down)
            // re-focusing would re-summon the keyboard the user dismissed, so skip it. The
            // host animates the band height back to 0 (with the field still mounted, item
            // 3), so the band shrink reads as one motion; do NOT snap it to 0 here or that
            // pre-empts the animation.
            if keyboardVisible, window != nil, !isDismantled {
                requestTerminalInputFocus()
            } else {
                inputSession.send(.releaseFocus)
            }
        }
        // The toolbar's visibility and reserved height do not change with the composer
        // (it stays shown while the keyboard is up either way), so re-seat the whole
        // bottom dock and re-sync the grid unconditionally: the composer band opening
        // or closing changes where the terminal grid bottom and the dock sit.
        updateDockedToolbarVisibility()
        layoutBottomDock()
        setNeedsGeometrySync()
        #if DEBUG
        // PILL/COMPOSER instrumentation (#5574 sink): one toggle line makes a single
        // device dogfood pass conclusive about whether the bar stays visible and
        // docks correctly while composing, since the simulator cannot show the
        // keyboard. Records the state that decides the bar's frame.
        let barFrame = dockedToolbarFrameInSurface ?? .zero
        MobileDebugLog.anchormux(
            "composer.toggle active=\(active) keyboardHeight=\(Int(keyboardHeight)) occInBounds=\(Int(keyboardOccupancyInBounds)) barHidden=\(dockedToolbar?.isHidden ?? true) barY=\(Int(barFrame.minY)) barH=\(Int(barFrame.height)) boundsH=\(Int(bounds.height))"
        )
        #endif
        // This structured transition contains only booleans, a bounded height,
        // and a fixed responder category, so it remains safe in Release logs.
        let frOwner = TerminalInputTextView.responderIdentity(of: CurrentResponderProbe().current())
        diagnosticLog?.record(DiagnosticEvent(
            .composerActiveTransition,
            ms: UInt32(max(0, keyboardHeight)),
            a: active ? 1 : 0,
            b: frOwner.rawValue,
            c: inputProxy.isFirstResponder ? 1 : 0
        ))
    }

    /// Whether the composer's hosted field currently holds first responder.
    ///
    /// The composer field is a SwiftUI `TextField` deep inside a `UIHostingController`
    /// mounted under ``composerContainer``, so `composerContainer.isFirstResponder` is
    /// always false (the container is not the responder, the nested field is). A
    /// recursive subtree walk (``UIView/firstResponderInSubtree()``) finds the actual
    /// first responder; it is the composer field iff that responder lives under the
    /// container. Drives the compose-button open/close-vs-refocus decision; false when
    /// the band is empty (no field mounted).
    private var composerFieldIsFirstResponder: Bool {
        guard !composerContainer.subviews.isEmpty else { return false }
        return composerContainer.firstResponderInSubtree() != nil
    }

    /// Resolve the current bottom-dock state and act on a compose-button tap so the
    /// draft is never lost across the compose → hide → reveal → compose cycle.
    ///
    /// The decision is the pure ``ComposerDockState/intentForComposeButtonTap()``
    /// reducer (unit-tested off-device); this method only reads the four live dock
    /// bits and maps the resulting ``ComposerDockIntent`` onto UIKit/delegate calls:
    ///
    /// - ``ComposerDockIntent/openComposer`` / ``ComposerDockIntent/closeComposer``:
    ///   forward the genuine toggle (open from nothing, or close a visible+focused
    ///   composer) to the host's `toggleComposer`.
    /// - ``ComposerDockIntent/revealAndFocusComposer``: the composer is presented but
    ///   suppressed by HIDE, or visible-yet-unfocused after a reveal. Bring the chrome
    ///   back if hidden, then ask the host to ensure-present + re-focus the field. The
    ///   presented flag is never toggled off, so the draft and band return intact —
    ///   this is the fix for the blind toggle that dismissed a still-presented composer.
    private func handleComposerButtonTap() {
        let dockState = ComposerDockState(
            chromeHidden: chromeHidden,
            composerPresented: composerActive,
            fieldFocused: composerFieldIsFirstResponder,
            keyboardUp: keyboardVisible
        )
        let intent = dockState.intentForComposeButtonTap()
        #if DEBUG
        lastComposerDockIntent = intent
        #endif
        switch intent {
        case .openComposer:
            // Optimistically flip the local mirror to the intent's outcome BEFORE
            // the store round-trip. `composerActive` is otherwise synced back via
            // SwiftUI's `updateUIView`, which runs a render pass after the store
            // mutation — a second tap landing inside that window would read the
            // stale flag, resolve `.openComposer` again, and the toggle would
            // dismiss the composer the first tap just presented. The authoritative
            // sync still arrives via `setComposerActive` (idempotent when the
            // optimistic value already matches).
            setComposerActive(true)
            requestComposerInputFocus()
            delegate?.ghosttySurfaceViewDidRequestComposerToggle(self)
        case .closeComposer:
            setComposerActive(false)
            delegate?.ghosttySurfaceViewDidRequestComposerToggle(self)
        case .revealAndFocusComposer:
            if chromeHidden {
                setChromeHidden(false)
            }
            delegate?.ghosttySurfaceViewDidRequestComposerFocus(self)
            requestComposerInputFocus()
        }
    }

    /// Install the composer band container into the surface's view hierarchy, above
    /// the docked toolbar. Hidden and zero-height until the host mounts a compose
    /// field into it (``mountComposerView(_:)``); the surface positions it in
    /// ``layoutBottomDock()`` and reserves its height in the grid. Auto Layout pins its
    /// bottom to ``UIView/keyboardLayoutGuide`` and pins the toolbar above it, so UIKit
    /// and the viewport coordinator share one keyboard edge.
    private func installComposerContainer() {
        composerContainer.backgroundColor = .clear
        composerContainer.isHidden = true
        // Do NOT clip: the composer's Liquid-Glass controls lift/shadow past the band
        // edge, and the band must sit above the Ghostty render layer (item 6) so the
        // glass is not clipped by the terminal bounds. Raised to the same chrome
        // z-position as the toolbar.
        composerContainer.clipsToBounds = false
        composerContainer.layer.zPosition = Self.bottomChromeZPosition
        bottomDockContainer.addSubview(composerContainer)
    }

    /// Mounts the host-built artifact chip inside the terminal's bottom-dock
    /// coordinate system, or hides it when `view` is `nil`.
    ///
    /// - Parameters:
    ///   - view: The hosted chip view, or `nil` when no visible paths exist.
    ///   - animated: Whether visibility changes should fade and slide.
    public func mountArtifactChipView(_ view: UIView?, animated: Bool) {
        artifactChipHost.setContent(view)
        updateArtifactChipVisibility(animated: animated)
    }

    private func installArtifactChipContainer() {
        artifactChipHost.install(in: self, zPosition: Self.artifactChipZPosition)
        installArtifactChipAccessibilityObservers()
    }

    /// The scroll-reveal gate is bypassed while VoiceOver or Switch Control
    /// runs; without observing their status changes, enabling one over an
    /// idle terminal would leave the only Files control hidden until some
    /// unrelated visibility update. Registered once with the chip container;
    /// block observers are removed automatically when the tokens deallocate
    /// with the view.
    private var artifactChipAccessibilityObserverTokens: [NSObjectProtocol] = []

    private func installArtifactChipAccessibilityObservers() {
        guard artifactChipAccessibilityObserverTokens.isEmpty else { return }
        let names: [Notification.Name] = [
            UIAccessibility.voiceOverStatusDidChangeNotification,
            UIAccessibility.switchControlStatusDidChangeNotification,
        ]
        artifactChipAccessibilityObserverTokens = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateArtifactChipVisibility(animated: true)
                }
            }
        }
    }

    /// Re-homes the artifact chip container into the host's keyboard-invariant
    /// chrome coordinate space — the same adoption ``moveBottomDock(to:)``
    /// performs for the dock. The keyboard slides the render wrapper (and this
    /// surface with it), never the host, so a chip anchored in host space
    /// stays at the terminal's visible top edge through every keyboard leg
    /// with no keyboard math of its own.
    func moveArtifactChip(to host: UIView) {
        artifactChipHost.install(in: host, zPosition: Self.artifactChipZPosition)
    }

    /// The view whose bounds match the SwiftUI representable that presents
    /// the artifact-files popover: the adopting host once the chrome is
    /// re-homed, else this surface. Popover anchors normalized against the
    /// sliding surface would drift downward by the keyboard slide.
    public var artifactChipAnchorReferenceView: UIView {
        bottomDockHostView ?? self
    }

    private var artifactChipShouldBeVisible: Bool {
        artifactChipHost.isRequestedVisible
            // Assistive technologies cannot reasonably perform a scroll to
            // reveal the only Files control, and the host hides its
            // accessibility descendants while invisible — so the transient
            // reveal is bypassed whenever VoiceOver or Switch Control runs.
            && (artifactChipScrollRevealed
                || UIAccessibility.isVoiceOverRunning
                || UIAccessibility.isSwitchControlRunning)
            && dockedToolbarShouldBeVisible
            && dockedToolbar?.isHidden == false
            && !zoomOverlayShown
    }

    private func updateArtifactChipVisibility(animated: Bool) {
        artifactChipHost.updateVisibility(
            shouldShow: artifactChipShouldBeVisible,
            animated: animated
        )
    }

    /// The chip is scroll-revealed: hidden at rest, shown while the user
    /// scrolls, and faded out after a short linger once scrolling settles —
    /// scrollbar-style, so it never sits over terminal content the user is
    /// reading. Mount state (whether there are files to show) is orthogonal
    /// and owned by the host content above.
    private var artifactChipScrollRevealed = false
    private var artifactChipRevealHideTask: Task<Void, Never>?
    /// Injected so the linger is testable and cancellable
    /// (`DispatchQueue.asyncAfter` is banned for intentional delays).
    var artifactChipRevealClock: any Clock<Duration> = ContinuousClock()
    /// How long the chip stays after the last scroll movement. Long enough to
    /// move a thumb from mid-screen to the chip and tap it.
    static let artifactChipRevealLinger: Duration = .seconds(2.2)

    /// Reveals the chip for a movement delta. Runs on every scroll frame, so
    /// it must do no task management: past the cheap guards it is a single
    /// bool flip per gesture. The fade-out linger is armed only by the
    /// drag-end/deceleration-end callbacks, and the user-driven guard keeps
    /// programmatic offset changes (recentering, scroll-to-bottom) from
    /// revealing a chip nobody is interacting with.
    private func noteArtifactChipScrollActivity() {
        // Deliberately NOT gated on mounted chip content: the scroll that
        // brings the first file into view finishes before the settled scan
        // mounts the chip, and the recorded reveal is what lets that mount
        // become visible without a second scroll.
        guard scrollMechanicsView.isTracking
                || scrollMechanicsView.isDragging
                || scrollMechanicsView.isDecelerating,
              !artifactChipScrollRevealed else { return }
        revealArtifactChipForScroll()
    }

    private func revealArtifactChipForScroll() {
        artifactChipRevealHideTask?.cancel()
        artifactChipRevealHideTask = nil
        if !artifactChipScrollRevealed {
            artifactChipScrollRevealed = true
            updateArtifactChipVisibility(animated: true)
        }
    }

    private func armArtifactChipRevealLinger() {
        artifactChipRevealHideTask?.cancel()
        artifactChipRevealHideTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.artifactChipRevealClock.sleep(
                for: Self.artifactChipRevealLinger,
                tolerance: nil
            )
            guard !Task.isCancelled else { return }
            self.artifactChipRevealHideTask = nil
            // A finger resting on the screen mid-drag produces no deltas;
            // keep the chip up until the touch actually ends.
            if self.scrollMechanicsView.isTracking {
                self.armArtifactChipRevealLinger()
                return
            }
            self.artifactChipScrollRevealed = false
            self.updateArtifactChipVisibility(animated: true)
        }
    }

    private func resetArtifactChipReveal() {
        artifactChipRevealHideTask?.cancel()
        artifactChipRevealHideTask = nil
        artifactChipScrollRevealed = false
    }

    /// Mount (or unmount, with `nil`) the host-built compose field into the surface's
    /// composer band. The terminal package cannot import the SwiftUI composer (that
    /// would invert the package DAG), so `GhosttySurfaceRepresentable` builds it in a
    /// `UIHostingController` and hands the controller's view here. The surface owns the
    /// band's height and grid reservation; the host owns the field's content and
    /// reports its measured height via ``setComposerBandHeight(_:animated:)``.
    ///
    /// The mounted view is pinned edge-to-edge inside the band with Auto Layout, so it
    /// fills the guide-pinned band — there is no second keyboard layout system fighting
    /// the surface for the band's frame.
    public func mountComposerView(_ view: UIView?) {
        composerContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let view else {
            composerContainer.isHidden = true
            return
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        composerContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: composerContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: composerContainer.bottomAnchor),
        ])
        composerContainer.isHidden = false
        composerContainer.layoutIfNeeded()
        inputSession.send(.lifecycleBoundary)
    }

    /// Set the height (points) the open composer band reserves below the docked
    /// toolbar, from the hosted compose field's intrinsic content size. Drives the
    /// grid reservation (so a field-grow pushes only the terminal up) and the dock
    /// layout. When `animated`, the reservation + reflow run inside a `UIView.animate`;
    /// keyboard movement itself remains owned by ``UIView/keyboardLayoutGuide``.
    /// Idempotent: a no-op when the height is
    /// unchanged (then `completion` runs immediately so an unmount-on-close never
    /// strands the mounted field).
    ///
    /// - Parameters:
    ///   - height: The compose field's measured height, clamped to non-negative.
    ///   - animated: Whether to animate the reflow (true for a live grow/shrink as the
    ///     user types and for the symmetric close; false for the initial mount, where
    ///     the open transition already animates).
    ///   - completion: Run after the reflow lands. The close path passes the field
    ///     unmount here so the band animates to 0 with the field STILL mounted (item 3:
    ///     a symmetric, coordinated close), and the field is removed only once the band
    ///     has collapsed — reversing the round-7 order that unmounted first and left the
    ///     band collapsing over empty space (the janky close).
    public func setComposerBandHeight(_ height: CGFloat, animated: Bool, completion: (() -> Void)? = nil) {
        let clamped = max(0, height)
        guard abs(clamped - composerBandHeight) > 0.5 else {
            completion?()
            return
        }
        composerBandHeight = clamped
        let apply = { [weak self] in
            guard let self else { return }
            self.layoutRenderedTerminalForCurrentViewport()
            self.layoutBottomDock()
            self.layoutBottomDockHierarchyIfNeeded()
        }
        if animated {
            animateDockReflow(animations: apply, completion: completion)
        } else {
            apply()
            completion?()
        }
        setNeedsGeometrySync()
    }

    /// Duration (seconds) used for dock reflows when no keyboard transition is active.
    private static let composerReflowDuration: TimeInterval = 0.25

    /// Toolbar geometry in the surface coordinate system. The toolbar is nested in
    /// ``bottomDockContainer``, so its raw `frame` is container-relative.
    private var dockedToolbarFrameInSurface: CGRect? {
        guard let dockedToolbar, dockedToolbar.superview != nil else { return nil }
        return dockedToolbar.convert(dockedToolbar.bounds, to: self)
    }

    /// Live toolbar geometry including the keyboard-driven presentation transform of
    /// its parent dock. Renderer clipping consumes this rather than reconstructing a
    /// keyboard animation from notification timing.
    private var dockedToolbarPresentationFrameInSurface: CGRect? {
        presentationFrameInSurface(of: dockedToolbar)
    }

    private func presentationFrameInSurface(of view: UIView?) -> CGRect? {
        guard let view,
              view.superview != nil,
              let presentationLayer = view.layer.presentation() else { return nil }
        let surfaceLayer = layer.presentation() ?? layer
        return presentationLayer.convert(view.bounds, to: surfaceLayer)
    }

    #if DEBUG
    private var currentInternalDockPresentationGap: CGFloat {
        guard dockedToolbarShouldBeVisible,
              dockedToolbar?.isHidden == false,
              !composerContainer.isHidden,
              let toolbarFrame = dockedToolbarPresentationFrameInSurface,
              let composerFrame = presentationFrameInSurface(of: composerContainer),
              toolbarFrame.height > 0.5,
              composerFrame.height > 0.5 else { return 0 }
        return abs(composerFrame.minY - toolbarFrame.maxY)
    }

    private func sampleInternalDockPresentationGap() {
        maximumInternalDockPresentationGap = max(
            maximumInternalDockPresentationGap,
            currentInternalDockPresentationGap
        )
    }
    #endif

    /// Apply dock heights from the same snapshot the terminal viewport consumes.
    private func layoutBottomDock() {
        layoutBottomDock(using: viewportSnapshot())
    }

    private func layoutBottomDock(using snapshot: TerminalViewportSnapshot) {
        composerHeightConstraint?.constant = snapshot.composerFrame.height
        toolbarHeightConstraint?.constant = min(
            reservedToolbarHeight,
            snapshot.toolbarFrame.height
        )
    }

    /// Lays out the hierarchy that owns the dock constraints. Once the dock moves
    /// into `GhosttySurfaceHostView`, laying out only the renderer cannot animate
    /// composer or toolbar height changes because those constraints are siblings.
    private func layoutBottomDockHierarchyIfNeeded() {
        (bottomDockHostView ?? self).layoutIfNeeded()
    }

    /// Animate the whole bottom dock to its current target frames.
    private func animateBottomDock() {
        animateDockReflow { [weak self] in
            guard let self else { return }
            self.layoutBottomDock()
            self.layoutBottomDockHierarchyIfNeeded()
            self.layoutRenderedTerminalForCurrentViewport()
        }
    }

    /// Reflow composer-height changes without replacing UIKit's keyboard-guide motion.
    private func animateDockReflow(
        animations: @escaping () -> Void,
        completion: (() -> Void)? = nil
    ) {
        UIView.animate(
            withDuration: Self.composerReflowDuration,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
            animations: animations,
            completion: { _ in completion?() }
        )
    }

    private var pinchAccumulatedScale: CGFloat = 1.0

    private func layoutScrollMechanicsView() {
        scrollMechanicsView.frame = bounds
        scrollMechanicsView.contentSize = CGSize(
            width: max(bounds.width, 1),
            height: max(Self.scrollMechanicsContentHeight, bounds.height * 8)
        )
        recenterScrollMechanicsViewIfNeeded(force: lastScrollMechanicsOffsetY == nil)
    }

    private func recenterScrollMechanicsViewIfNeeded(force: Bool = false) {
        let contentHeight = scrollMechanicsView.contentSize.height
        let visibleHeight = max(scrollMechanicsView.bounds.height, 1)
        let currentY = scrollMechanicsView.contentOffset.y
        let edgeMargin = visibleHeight * 2
        guard force || currentY < edgeMargin || currentY > contentHeight - visibleHeight - edgeMargin else {
            return
        }

        let centeredY = max(0, (contentHeight - visibleHeight) / 2)
        scrollMechanicsIsRecentering = true
        scrollMechanicsView.setContentOffset(CGPoint(x: 0, y: centeredY), animated: false)
        lastScrollMechanicsOffsetY = centeredY
        scrollMechanicsIsRecentering = false
    }

    /// Accumulates one native scroll delta for the display-link flush.
    ///
    /// The scroll view callback is the production caller. Keeping this method
    /// internal also lets the terminal package exercise the real accumulation
    /// path with `@testable import`, without adding a debug-only production
    /// entrypoint.
    func enqueueScrollMechanicsDelta(_ deltaY: CGFloat, touchPoint: CGPoint) {
        // The transparent UIScrollView supplies native iOS tracking,
        // deceleration, and momentum. The Mac still owns terminal semantics:
        // normal-screen scrollback and alt-screen mouse-wheel delivery.
        guard deltaY != 0 else { return }
        let interactionGeneration = recordUserViewportScrollInteraction()
        // User-driven movement reveals the chip; this is guard-only work per
        // frame (the linger is armed by the gesture-end callbacks).
        noteArtifactChipScrollActivity()
        let cellHeightPt = cellPixelSize.height / max(preferredScreenScale, 1)
        let divisor = cellHeightPt > 1 ? Double(cellHeightPt) * 3 : 42
        pendingScrollLines += -Double(deltaY) / divisor
        // Same direction in device pixels: the pixel position is the viewport
        // top's distance from the top of scrollback, so a finger drag DOWN
        // (negative deltaY, positive lines, older content) decreases it.
        pendingScrollPixels += Double(deltaY) * Double(max(preferredScreenScale, 1))
        pendingScrollCell = scrollCell(at: touchPoint)
        pendingScrollInteractionGeneration = interactionGeneration
    }

    /// Coalesced native scroll forwarded to the Mac once per display-link frame.
    private var pendingScrollLines: Double = 0
    /// The same coalesced deltas in device pixels for the pixel-precise local path.
    private var pendingScrollPixels: Double = 0
    private var pendingScrollCell: (col: Int, row: Int) = (0, 0)
    private var pendingScrollInteractionGeneration: UInt64?
    var pendingLocalScrollLines: Double = 0
    var pendingLocalScrollCell: (col: Int, row: Int) = (0, 0)
    var pendingLocalScrollInteractionGeneration: UInt64?
    var localScrollApplyInFlight = false
    var localScrollApplyInFlightGeneration: UInt64?
    var pendingLocalScrollPixels: Double = 0
    var pendingLocalPixelScrollInteractionGeneration: UInt64?
    var localPixelScrollApplyInFlight = false
    var localPixelScrollApplyInFlightGeneration: UInt64?
    /// A verified replay completed mid-gesture: run one zero-delta pixel
    /// batch to re-assert the held position over the replay's bottom reset.
    var pendingLocalPixelScrollReassert = false
    /// When line-path (alt/TUI) deceleration began; the flush kills the
    /// momentum tail after ``linePathDecelerationBudget`` so a flick cannot
    /// keep scrolling a full-screen app for seconds.
    private var linePathDecelerationStartedAt: CFTimeInterval?
    private static let linePathDecelerationBudget: CFTimeInterval = 0.45
    /// Sub-line remainder from whole-line dispatch on the line path. Kept
    /// out of `pendingScrollLines` so a leftover fraction cannot re-trigger
    /// the flush (and record interactions) with no real gesture delta.
    private var linePathFractionCarry: Double = 0
    var pendingLocalScrollDrains: [(generation: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []

    /// Drops scroll work tied to a surface generation that will no longer run.
    func resetScrollStateForSurfaceReplacement() {
        pendingScrollLines = 0
        linePathFractionCarry = 0
        pendingScrollPixels = 0
        pendingScrollInteractionGeneration = nil
        pendingLocalScrollLines = 0
        pendingLocalScrollInteractionGeneration = nil
        localScrollApplyInFlight = false
        localScrollApplyInFlightGeneration = nil
        localScrollApplyStartedAt = nil
        localScrollApplyToken = nil
        pendingLocalScrollPixels = 0
        pendingLocalPixelScrollInteractionGeneration = nil
        localPixelScrollApplyInFlight = false
        localPixelScrollApplyInFlightGeneration = nil
        localPixelScrollApplyStartedAt = nil
        localPixelScrollApplyToken = nil
        pendingLocalPixelScrollReassert = false
        localPixelScrollState.withLock {
            let epoch = $0.epoch
            $0 = .init()
            $0.epoch = epoch &+ 1
        }
        scrollToBottomInFlight = false
        scrollToBottomRequested = false
        scrollToBottomRetryCount = 0
        scrollToBottomRetryAt = nil
        scrollToBottomInteractionGeneration = nil
        completePendingLocalScrollDrains(returning: false)
    }

    /// Map a touch point to a grid cell (shared effective grid with the Mac), so
    /// alt-screen mouse-wheel reports at the cell under the finger.
    private func scrollCell(at point: CGPoint) -> (col: Int, row: Int) {
        let scale = max(preferredScreenScale, 1)
        let cellW = max(cellPixelSize.width / scale, 1)
        let cellH = max(cellPixelSize.height / scale, 1)
        let col = max(0, Int((point.x - lastRenderRect.minX) / cellW))
        let row = max(0, Int((point.y - lastRenderRect.minY) / cellH))
        return (col, row)
    }

    @discardableResult
    private func flushPendingScrollIfNeeded() -> (generation: UInt64, appliedLocally: Bool)? {
        guard pendingScrollLines != 0 else { return nil }
        let lines = pendingScrollLines
        let pixels = pendingScrollPixels
        let cell = pendingScrollCell
        let generation = pendingScrollInteractionGeneration
            ?? recordUserViewportScrollInteraction()
        pendingScrollLines = 0
        pendingScrollPixels = 0
        pendingScrollInteractionGeneration = nil
        let appliedLocally = scrollPresentationAuthority.appliesLocally
        var dispatchLines = lines
        if appliedLocally {
            // Pixel-precise local scroll only where the phone owns
            // primary-screen scrolling (the confirmed-primary condition that
            // also suppresses the Mac scroll RPC). Alt screens and legacy
            // transports keep the row-quantized line path.
            if pixels != 0,
               delegate?.ghosttySurfaceViewOwnsLocalPrimaryScreenScroll(self) == true {
                // Entering the pixel path: drop any line-path residue so a
                // sub-line fraction from an earlier alt gesture cannot leak
                // into a later line-path dispatch.
                linePathFractionCarry = 0
                linePathDecelerationStartedAt = nil
                applyLocalPixelScroll(
                    pixels: pixels,
                    interactionGeneration: generation
                )
            } else {
                // Routing to the line path (alt screen or legacy transport):
                // drop any pixel-path residue so a primary->alt flip cannot
                // carry a held anchor or re-assert into the TUI's screen.
                pendingLocalScrollPixels = 0
                pendingLocalPixelScrollReassert = false
                localPixelScrollState.withLock {
                    $0.epoch &+= 1
                    $0.remainderPx = 0
                    $0.lastApplied = nil
                    $0.topRevealPx = 0
                }
                // TUI scroll feel: dispatch whole lines only, carrying the
                // fraction in its own accumulator, so the app sees clean
                // steps instead of a 120Hz fragment stream; and cap the
                // momentum tail so a flick cannot keep scrolling a
                // full-screen app for seconds. The carry lives OUTSIDE
                // pendingScrollLines so a sub-line leftover cannot re-trigger
                // the flush every frame and churn interaction generations.
                let totalLines = linePathFractionCarry + lines
                let wholeLines = totalLines < 0
                    ? totalLines.rounded(.up)
                    : totalLines.rounded(.down)
                linePathFractionCarry = totalLines - wholeLines
                dispatchLines = wholeLines
                if scrollMechanicsView.isDecelerating {
                    let now = CACurrentMediaTime()
                    if let startedAt = linePathDecelerationStartedAt {
                        if now - startedAt > Self.linePathDecelerationBudget {
                            scrollMechanicsView.setContentOffset(
                                scrollMechanicsView.contentOffset,
                                animated: false
                            )
                            pendingScrollLines = 0
                            linePathFractionCarry = 0
                            dispatchLines = 0
                        }
                    } else {
                        linePathDecelerationStartedAt = now
                    }
                } else {
                    linePathDecelerationStartedAt = nil
                }
                if dispatchLines != 0 {
                    applyLocalScrollbackScroll(
                        lines: dispatchLines,
                        col: cell.col,
                        row: cell.row,
                        interactionGeneration: generation
                    )
                }
            }
        }
        if dispatchLines != 0 {
            delegate?.ghosttySurfaceView(self, didScrollLines: dispatchLines, atCol: cell.col, row: cell.row)
        }
        return (generation, appliedLocally)
    }

    /// Pulls a pending native scroll batch into the replay transaction before
    /// revealing the verified renderer. Without this drain, a render-grid
    /// update can reveal the pre-scroll viewport for one frame while the
    /// display-link batch is still waiting behind the frozen presentation.
    ///
    /// This transaction owns only the work present when it is admitted. New
    /// gesture callbacks belong to the next presentation. Chasing newly
    /// produced scroll batches here can keep this main-actor task runnable for
    /// the entire gesture and trip iOS's scene-update watchdog.
    @discardableResult
    public func drainPendingScrollForVerifiedReplayReveal() async -> Bool {
        let targetGeneration: UInt64
        if let flushed = flushPendingScrollIfNeeded() {
            guard flushed.appliedLocally else { return false }
            targetGeneration = flushed.generation
        } else if let pendingGeneration = pendingLocalScrollTargetGenerationForReveal() {
            targetGeneration = pendingGeneration
        } else {
            return false
        }
        return await waitForLocalScrollApplied(upTo: targetGeneration)
    }

    private func pendingLocalScrollTargetGenerationForReveal() -> UInt64? {
        var generation: UInt64?
        if pendingLocalScrollLines != 0,
           let pendingLocalScrollInteractionGeneration {
            generation = max(generation ?? 0, pendingLocalScrollInteractionGeneration)
        }
        if localScrollApplyInFlight,
           let localScrollApplyInFlightGeneration {
            generation = max(generation ?? 0, localScrollApplyInFlightGeneration)
        }
        if pendingLocalScrollPixels != 0,
           let pendingLocalPixelScrollInteractionGeneration {
            generation = max(generation ?? 0, pendingLocalPixelScrollInteractionGeneration)
        }
        if localPixelScrollApplyInFlight,
           let localPixelScrollApplyInFlightGeneration {
            generation = max(generation ?? 0, localPixelScrollApplyInFlightGeneration)
        }
        return generation
    }

    /// A tap both raises the software keyboard (so the user can type) and
    /// forwards a left click at the tapped cell to the Mac. The Mac's libghostty
    /// self-gates: TUIs with mouse reporting get the click; a normal screen
    /// treats it as a harmless empty selection, so tapping a shell still just
    /// focuses input.
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // A tap re-reveals chrome the HIDE button suppressed (item 2). Done before
        // forwarding the tap/focus so the toolbar (and any open composer) animate back
        // in as the keyboard comes up. Capture the pre-reveal state: a reveal that
        // brings back a still-presented composer must restore focus to the COMPOSER
        // field, not the terminal proxy — otherwise the next compose-button tap reads
        // "presented but unfocused" and the prior round dismissed it, losing the draft.
        let wasHidden = chromeHidden
        if chromeHidden {
            setChromeHidden(false)
        }
        let cell = scrollCell(at: gesture.location(in: self))
        let tapIntent = delegate?.ghosttySurfaceView(
            self,
            inputPolicyForTapAtCol: cell.col,
            row: cell.row
        ) ?? .immediateInput
        var deferredTapID: UInt64?
        switch tapIntent {
        case .immediateInput:
            // A fresh cache proved this is ordinary terminal content, so input
            // ownership is synchronous and independent of the async Mac click.
            // Click-generation invalidation cannot starve this focus request.
            if wasHidden, composerActive {
                requestComposerInputFocus()
            } else {
                deferredTapID = inputSession.send(
                    .terminalTapped(.immediateInput)
                ).deferredTapID
            }
        case .deferForArtifactDecision:
            deferredTapID = inputSession.send(
                .terminalTapped(.deferForArtifactDecision)
            ).deferredTapID
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let disposition = await self.delegate?.ghosttySurfaceView(
                self,
                didTapAtCol: cell.col,
                row: cell.row
            ) ?? .focusTerminal
            guard let deferredTapID else { return }
            let resolution: TerminalDeferredTapResolution = switch disposition {
            case .focusTerminal: .focusTerminal
            case .openedArtifact: .artifactHandled
            case .ignored: .ignored
            }
            self.inputSession.send(
                .deferredTerminalTapResolved(id: deferredTapID, resolution: resolution)
            )
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchAccumulatedScale = 1.0
        case .changed:
            let delta = gesture.scale - pinchAccumulatedScale
            if abs(delta) >= 0.15 {
                let direction: TerminalFontZoomDirection = delta > 0 ? .increase : .decrease
                if performFontZoom(direction) {
                    pinchAccumulatedScale = gesture.scale
                }
            }
        case .ended, .cancelled:
            // Final sync to make sure the last font change is applied.
            setNeedsGeometrySync()
        default:
            break
        }
    }

    @discardableResult
    private func performFontZoom(_ direction: TerminalFontZoomDirection) -> Bool {
        // Coalesce zoom: each tap only updates `pendingFontSize`; the display
        // link applies the LATEST target once per frame via an absolute
        // `set_font_size` (see `applyPendingFontSizeIfNeeded`). A burst of taps
        // therefore becomes one libghostty push + one resize per frame instead
        // of one per tap.
        //
        // Why this matters: every libghostty surface op on iOS runs on the
        // serial `outputQueue`, and they all BLOCK — the font push is a
        // `.forever` mailbox push, and the render that drains it waits on a
        // free GPU frame. Dispatching one blocking push per tap let the queue
        // accumulate pushes faster than the per-frame render drained them, so
        // the queue wedged and zoom froze. Coalescing caps the work at one
        // push per frame, which the render keeps pace with.
        //
        // Base the next step on `pendingFontSize` when a target is already
        // queued, so taps within the same frame still accumulate correctly.
        let delta: Float32 = direction == .increase ? 1 : -1
        let base = pendingFontSize ?? liveFontSize
        let target = base + delta
        guard target >= MobileTerminalFontPreference.minimumSize,
              target <= MobileTerminalFontPreference.maximumSize else {
            MobileDebugLog.anchormux("zoom.clamp dir=\(direction) base=\(base) target=\(target) range=[\(MobileTerminalFontPreference.minimumSize),\(MobileTerminalFontPreference.maximumSize)]")
            return false
        }
        guard surface != nil else { return false }

        pendingFontSize = target
        // A pinch/accessory step is an explicit choice: it moves the user
        // baseline that capacity reports (and the converge-to-base step)
        // derive from.
        userBaseFontSize = target
        MobileDebugLog.anchormux("zoom.queue dir=\(direction) \(base)->\(target) live=\(liveFontSize)")
        scheduleDisplayLinkWork()
        showZoomOverlay()
        delegate?.ghosttySurfaceView(
            self,
            didChangeZoom: direction == .increase ? .stepIncrease : .stepDecrease
        )
        return true
    }

    /// Ensure a queued zoom (`pendingFontSize`) actually gets applied. While the
    /// display link runs, `handleDisplayLinkFire` picks the target up on the
    /// next frame. If the link is stopped (detached / backgrounded) nothing
    /// would pump it, so apply immediately.
    private func scheduleDisplayLinkWork() {
        needsDraw = true
        if displayLink == nil {
            applyPendingFontSizeIfNeeded()
        }
    }

    /// Apply the latest queued zoom target, called once per display-link frame.
    /// Pushes an absolute `set_font_size` off the main thread and renders the
    /// new font WITHOUT resizing the surface — geometry is resynced once after
    /// zoom settles (see `zoomSettleFrames`). Returns whether a font change was
    /// applied this frame.
    @discardableResult
    private func applyPendingFontSizeIfNeeded() -> Bool {
        guard let target = pendingFontSize, let surface else { return false }
        pendingFontSize = nil
        guard target != liveFontSize else { return false }
        liveFontSize = target
        MobileDebugLog.anchormux("zoom.apply \(target) eff=\(effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "nil")")
        // Absolute set: the prior `±1` binding action drove libghostty's own
        // font counter independently of our clamp, so a fast burst could push
        // it past `maximumSize` toward the 255pt ceiling and collapse the grid.
        // An absolute `set_font_size:<target>` keeps libghostty in lockstep
        // with `liveFontSize`, which we keep inside [minimumSize, maximumSize].
        let action = "set_font_size:\(target)"
        outputQueue.async {
            action.withCString { pointer in
                _ = ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
            }
        }
        // Render the new font (the grid reflows inside the current surface) but
        // do NOT resize the surface this frame. Resizing the render target on
        // every zoom step reallocates the IOSurface and stalls `render_now`'s
        // GPU frame wait (the wedge). Defer one geometry resync until zoom goes
        // quiet via the settle counter, re-armed on every apply.
        needsDraw = true
        zoomSettleFrames = Self.zoomSettleFrameThreshold
        return true
    }

    /// Drive the live terminal font to an absolute point size from outside the
    /// surface (the Mac-pushed `terminal.set_font` event, routed through the
    /// representable's coordinator). Funnels through the same shared
    /// ``applyAbsoluteFontSize(_:)`` apply path as a pinch step or the
    /// zoom-control overlay, so there is one clamp + reflow path, then refreshes
    /// the zoom HUD so the on-screen size tracks the remote change.
    public func setLiveFontSize(_ points: Float32) {
        delegate?.ghosttySurfaceView(self, didChangeZoom: .hostSet)
        applyUserFontSize(points)
        zoomOverlay?.updateZoom(points: pendingFontSize ?? liveFontSize)
    }

    /// An EXPLICIT font choice (pinch step, overlay reset, Mac push): moves the
    /// user baseline that capacity reports and the auto-fit derive from, then
    /// drives the shared apply path.
    private func applyUserFontSize(_ target: Float32) {
        userBaseFontSize = min(
            max(target, MobileTerminalFontPreference.minimumSize),
            MobileTerminalFontPreference.maximumSize
        )
        applyAbsoluteFontSize(target)
    }

    /// Set the live zoom to an absolute size (clamped to the font range),
    /// driving the same coalesced apply path as a pinch step. Does NOT move
    /// the user baseline; the geometry pass funnels its converge-to-base
    /// step through here.
    func applyAbsoluteFontSize(_ target: Float32) {
        guard surface != nil else { return }
        let clamped = min(
            max(target, MobileTerminalFontPreference.minimumSize),
            MobileTerminalFontPreference.maximumSize
        )
        pendingFontSize = clamped
        MobileDebugLog.anchormux("zoom.absolute target=\(target) clamped=\(clamped) live=\(liveFontSize)")
        scheduleDisplayLinkWork()
    }

    /// Present (or refresh) the zoom-control HUD and restart its auto-fade
    /// timer. Called on every zoom step so the header tracks the live size.
    private func showZoomOverlay() {
        let overlay = ensureZoomOverlay()
        overlay.updateZoom(points: pendingFontSize ?? liveFontSize)
        zoomOverlayLastInteraction = CACurrentMediaTime()
        if !zoomOverlayShown {
            zoomOverlayShown = true
            updateArtifactChipVisibility(animated: true)
            overlay.isHidden = false
            bringSubviewToFront(overlay)
            UIView.animate(withDuration: 0.18) { overlay.alpha = 1 }
        }
        layoutZoomOverlay()
    }

    private func fadeOutZoomOverlay() {
        guard zoomOverlayShown, let overlay = zoomOverlay else { return }
        zoomOverlayShown = false
        UIView.animate(
            withDuration: 0.3,
            animations: { overlay.alpha = 0 },
            completion: { [weak self, weak overlay] _ in
                if overlay?.alpha == 0 { overlay?.isHidden = true }
                self?.updateArtifactChipVisibility(animated: true)
            }
        )
    }

    private func ensureZoomOverlay() -> MobileTerminalZoomControlOverlay {
        if let zoomOverlay {
            zoomOverlay.applyTheme(terminalTheme)
            return zoomOverlay
        }
        let overlay = MobileTerminalZoomControlOverlay()
        overlay.applyTheme(terminalTheme)
        overlay.alpha = 0
        overlay.isHidden = true
        overlay.layer.zPosition = 1100
        overlay.onInteraction = { [weak self] in
            self?.zoomOverlayLastInteraction = CACurrentMediaTime()
        }
        overlay.onResetToDefault = { [weak self] in
            guard let self else { return }
            self.delegate?.ghosttySurfaceView(self, didUseToolbarAction: .zoomResetToDefault)
            self.delegate?.ghosttySurfaceView(self, didChangeZoom: .resetToDefault)
            let target = self.zoomPreference.savedFontSize
                ?? MobileTerminalFontPreference.defaultSize
            self.applyUserFontSize(target)
            self.zoomOverlay?.updateZoom(points: target)
        }
        overlay.onSaveAsDefault = { [weak self] in
            guard let self else { return }
            self.delegate?.ghosttySurfaceView(self, didUseToolbarAction: .zoomSaveAsDefault)
            self.zoomPreference.save(self.pendingFontSize ?? self.liveFontSize)
        }
        overlay.onRestoreBuiltIn = { [weak self] in
            guard let self else { return }
            self.delegate?.ghosttySurfaceView(self, didUseToolbarAction: .zoomRestoreBuiltIn)
            self.delegate?.ghosttySurfaceView(self, didChangeZoom: .restoreBuiltIn)
            self.zoomPreference.clear()
            self.applyUserFontSize(MobileTerminalFontPreference.defaultSize)
            self.zoomOverlay?.updateZoom(points: MobileTerminalFontPreference.defaultSize)
        }
        addSubview(overlay)
        zoomOverlay = overlay
        layoutZoomOverlay()
        return overlay
    }

    /// Center the zoom HUD in the area above the keyboard / toolbar.
    private func layoutZoomOverlay() {
        guard let zoomOverlay else { return }
        let fitting = zoomOverlay.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let size = CGSize(width: max(fitting.width, 220), height: max(fitting.height, 1))
        let availableH = max(1, viewportSnapshot().layoutViewportRect.height)
        zoomOverlay.bounds = CGRect(origin: .zero, size: size)
        zoomOverlay.center = CGPoint(x: bounds.midX, y: availableH * 0.45)
    }

    #if DEBUG
    /// Repro hook for the `CMUX_ZOOM_STRESS` harness: drive one font-zoom
    /// step exactly as pinch / the accessory buttons do, so the harness can
    /// hammer the zoom path and reproduce the fast-zoom crash locally.
    func debugStressZoomStep(_ direction: TerminalFontZoomDirection) {
        performFontZoom(direction)
    }

    func debugEnqueueScrollForTesting(deltaY: CGFloat, touchPoint: CGPoint) {
        enqueueScrollMechanicsDelta(deltaY, touchPoint: touchPoint)
    }

    #endif

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        disposeSurface()
    }

    public override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let snapshot = viewportSnapshot()
        layoutBottomDock(using: snapshot)
        layoutRenderedTerminalForCurrentViewport(using: snapshot)
        layoutScrollMechanicsView()
        #if DEBUG
        debugAccessibilityProxy.frame = bounds
        // The dock probe stays a 1×1 off-screen carrier; its accessibility value is
        // computed live on every read (see ``composerDockProbeValue``), so it never
        // needs a frame-driven refresh.
        composerDockProbe.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        #endif
        inputProxy.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        inputProxy.updateAccessoryLayoutInsets()
        layoutZoomOverlay()
        MobileDebugLog.anchormux("surface.layout bounds=\(Int(bounds.width))x\(Int(bounds.height)) window=\(window != nil)")
        if bounds.size != lastLayoutGeometrySyncSize {
            #if DEBUG
            // Ancestor-frame dump on every size change: pinpoints which hosting
            // view reshaped the surface (e.g. keyboard-coupled SwiftUI safe-area
            // churn). Fires only on actual size changes, so it is quiet in
            // steady state.
            var chainNode: UIView? = self
            var chain: [String] = []
            while let node = chainNode {
                chain.append(
                    "\(String(describing: type(of: node)).prefix(38)) "
                    + "y=\(Int(node.frame.minY)) h=\(Int(node.frame.height)) "
                    + "sab=\(Int(node.safeAreaInsets.bottom))"
                )
                chainNode = node.superview
            }
            MobileDebugLog.anchormux("kb.chain " + chain.joined(separator: " | "))
            #endif
            lastLayoutGeometrySyncSize = bounds.size
            setNeedsGeometrySync()
        }
        syncSurfaceVisibility()
    }

    /// Re-seats the bottom dock and grid reservation when the safe-area inset
    /// changes.
    ///
    /// The always-visible toolbar rides the bottom safe area while the keyboard
    /// is down (Round 8). The inset can arrive after the first layout (it is 0
    /// before window attach), so re-seat the dock and re-reserve the grid when it
    /// changes; otherwise the toolbar would sit on the home indicator until the
    /// next unrelated relayout.
    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        #if DEBUG
        if let keyboardHeightOverrideForTesting {
            setKeyboardHeightOverrideForTesting(keyboardHeightOverrideForTesting)
        }
        #endif
        let snapshot = viewportSnapshot()
        layoutBottomDock(using: snapshot)
        layoutRenderedTerminalForCurrentViewport(using: snapshot)
        setNeedsGeometrySync()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        MobileDebugLog.anchormux("surface.didMoveToWindow window=\(window != nil)")
        syncSurfaceVisibility()
        if window != nil {
            isDismantled = false
            setNeedsLayout()
            if UIApplication.shared.applicationState == .active {
                inputSession.send(.sceneDidBecomeActive)
            } else {
                inputSession.send(.sceneWillResignActive)
            }
            #if DEBUG
            debugAccessibilityProxy.isAccessibilityElement = true
            #endif
            setNeedsGeometrySync()
            setFocus(true)
            if autoFocusOnWindowAttach, UIApplication.shared.applicationState == .active {
                focusInput()
            }
            resetVisibleArtifactCountTracking()
            startDisplayLink()
            delegate?.ghosttySurfaceView(self, didChangeWindowAttachment: true)
        } else {
            delegate?.ghosttySurfaceView(self, didChangeWindowAttachment: false)
            prepareForReuseAfterDetach()
        }
    }

    private var lastProcessOutputLogTime: CFTimeInterval = 0

    public func processOutput(_ data: Data) {
        processOutput(data, completion: nil)
    }

    func makeSurfaceOperationID() -> UInt64 {
        nextSurfaceOperationID &+= 1
        return nextSurfaceOperationID
    }

    func ensureSurfaceOperationDeadlinePump() {
        guard window != nil, displayLink == nil, !renderingSuspended, !renderPipelineRecoveryPaused else { return }
        startDisplayLink()
    }

    func registerPendingOutputApply(
        byteCount: Int,
        continuation: CheckedContinuation<Bool, Never>
    ) -> UInt64 {
        let operationID = makeSurfaceOperationID()
        if let existing = pendingOutputApply {
            pendingOutputApply = nil
            let elapsedMs = Int((CACurrentMediaTime() - existing.startedAt) * 1000)
            MobileDebugLog.anchormux("output.apply.OVERLAP elapsedMs=\(elapsedMs)")
            existing.continuation.resume(returning: false)
        }
        pendingOutputApply = PendingSurfaceOperation(
            id: operationID,
            startedAt: CACurrentMediaTime(),
            byteCount: byteCount,
            continuation: continuation
        )
        ensureSurfaceOperationDeadlinePump()
        return operationID
    }

    @discardableResult
    func completePendingOutputApply(id: UInt64, returning result: Bool) -> Bool {
        guard let pending = pendingOutputApply, pending.id == id else { return false }
        pendingOutputApply = nil
        pending.continuation.resume(returning: result)
        return true
    }

    private func registerPendingGeometryApply(
        continuation: CheckedContinuation<Bool, Never>
    ) -> UInt64 {
        let operationID = makeSurfaceOperationID()
        if let existing = pendingGeometryApply {
            pendingGeometryApply = nil
            let elapsedMs = Int((CACurrentMediaTime() - existing.startedAt) * 1000)
            MobileDebugLog.anchormux("geometry.apply.OVERLAP elapsedMs=\(elapsedMs)")
            existing.continuation.resume(returning: false)
        }
        pendingGeometryApply = PendingSurfaceOperation(
            id: operationID,
            startedAt: CACurrentMediaTime(),
            byteCount: nil,
            continuation: continuation
        )
        ensureSurfaceOperationDeadlinePump()
        return operationID
    }

    @discardableResult
    private func completePendingGeometryApply(id: UInt64, returning result: Bool) -> Bool {
        guard let pending = pendingGeometryApply, pending.id == id else { return false }
        pendingGeometryApply = nil
        pending.continuation.resume(returning: result)
        return true
    }

    @discardableResult
    func completePendingSurfaceOperations(returning result: Bool) -> Bool {
        var completed = false
        if let pending = pendingOutputApply {
            pendingOutputApply = nil
            pending.continuation.resume(returning: result)
            completed = true
        }
        if let pending = pendingGeometryApply {
            pendingGeometryApply = nil
            pending.continuation.resume(returning: result)
            completed = true
        }
        if let pending = pendingVerifiedReplayViewportAnchorCapture {
            pendingVerifiedReplayViewportAnchorCapture = nil
            pending.continuation.resume(returning: nil)
            completed = true
        }
        if let pending = pendingVerifiedReplayViewportAnchorRestore {
            pendingVerifiedReplayViewportAnchorRestore = nil
            viewportRestoreGate.withLock { $0.activeRestoreTicket = nil }
            pending.continuation.resume(returning: false)
            completed = true
        }
        if let pending = pendingVerifiedReplayPresentation {
            pendingVerifiedReplayPresentation = nil
            pending.continuation.resume(returning: nil)
            completed = true
        }
        skipPendingVisibleSnapshot()
        skipPendingCopyableTextRead()
        return completed
    }

    private func skipPendingVisibleSnapshot() {
        guard let pending = pendingVisibleSnapshot else { return }
        pendingVisibleSnapshot = nil
        pending.continuation.resume(returning: nil)
    }

    private func skipPendingCopyableTextRead() {
        guard let pending = pendingCopyableTextRead else { return }
        pendingCopyableTextRead = nil
        pending.cancel()
        pending.continuation.resume(returning: nil)
    }

    @discardableResult
    func completePendingVisibleSnapshot(
        id: UInt64,
        returning snapshot: (text: String, columns: Int)?
    ) -> Bool {
        guard let pending = pendingVisibleSnapshot, pending.id == id else { return false }
        pendingVisibleSnapshot = nil
        pending.continuation.resume(returning: snapshot)
        return true
    }

    @discardableResult
    private func completePendingCopyableTextRead(id: UInt64, returning text: String?) -> Bool {
        guard let pending = pendingCopyableTextRead, pending.id == id else { return false }
        pendingCopyableTextRead = nil
        pending.cancel()
        pending.continuation.resume(returning: text)
        return true
    }

    func processOutput(
        _ data: Data,
        terminalConfigTheme outputConfigTheme: TerminalTheme? = nil,
        completion: (@MainActor @Sendable (Bool) -> Void)?
    ) {
        guard !renderPipelineRecoveryPaused else {
            logRecoveryPausedDrop(kind: "output", byteCount: data.count)
            completion?(false)
            return
        }
        guard let surface, !isDismantled else {
            completion?(true)
            return
        }
        #if DEBUG
        if lastInputTimestamp > 0 {
            let elapsed = (CACurrentMediaTime() - lastInputTimestamp) * 1000.0
            lastInputTimestamp = 0
            latencySamples.append(elapsed)
            if latencySamples.count % 10 == 0 {
                let sorted = latencySamples.sorted()
                let avg = latencySamples.reduce(0, +) / Double(latencySamples.count)
                let p50 = sorted[sorted.count / 2]
                let p95 = sorted[Int(Double(sorted.count) * 0.95)]
                log.debug("Keypress latency (\(self.latencySamples.count, privacy: .public) samples): avg=\(avg, privacy: .public)ms p50=\(p50, privacy: .public)ms p95=\(p95, privacy: .public)ms min=\(sorted.first!, privacy: .public)ms max=\(sorted.last!, privacy: .public)ms")
            }
        }
        #endif
        let forwarded = Self.forwardDaemonOutputBytes(data)
        // The blank-band measurement only steers live absorption while a
        // keyboard is up; keep a slow warm value otherwise so the NEXT raise
        // has one, without scanning the viewport on every output burst.
        let contentMeasurementInterval: CFTimeInterval = keyboardVisible ? 0.25 : 1.0
        let generation = surfaceGeneration
        let outputConfigTheme = outputConfigTheme?.validatedOrDefault()
        let configThemeToApply = outputConfigTheme.flatMap { theme in
            appliedTerminalConfigTheme == theme ? nil : theme
        }
        let preparedConfigBits = configThemeToApply
            .flatMap { runtime?.makeThemeConfig($0) }
            .map { Int(bitPattern: $0) }
        if let outputConfigTheme, preparedConfigBits != nil {
            appliedTerminalConfigTheme = outputConfigTheme
        }
        // `ghostty_surface_process_output` BLOCKS on libghostty's internal
        // renderer/IO synchronization (a futex). Device crash logs show it
        // hanging the main thread (`Thread.Futex.Deadline.wait`) until the
        // scene-update watchdog (0x8BADF00D) kills the app. It must run off
        // the main thread. Feed it on a serial background queue (order
        // preserved) and hop back to main only for the Swift-side UI state.
        let workQueue = outputQueue
        workQueue.async { [weak self] in
            if let preparedConfigBits,
               let preparedConfig = ghostty_config_t(bitPattern: preparedConfigBits) {
                ghostty_surface_update_theme_config(surface, preparedConfig)
                ghostty_config_free(preparedConfig)
            }
            #if DEBUG
            let outputApplyStartedAt = CACurrentMediaTime()
            #endif
            forwarded.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                let pointer = baseAddress.assumingMemoryBound(to: CChar.self)
                ghostty_surface_process_output(surface, pointer, UInt(buffer.count))
            }
            #if DEBUG
            // Perf probe for the scroll-hitch investigation: a VT apply on this
            // serial queue delays any queued scroll-position batch by its full
            // duration (head-of-line blocking). Log slow applies, rate-limited.
            let outputApplyMs = (CACurrentMediaTime() - outputApplyStartedAt) * 1000
            if outputApplyMs > 8 {
                let perfNow = CACurrentMediaTime()
                if perfNow - workQueue.lastOutputPerfLogTime >= 0.25 {
                    workQueue.lastOutputPerfLogTime = perfNow
                    MobileDebugLog.anchormux(
                        "perf.process_output ms=\(Int(outputApplyMs)) bytes=\(forwarded.count)"
                    )
                }
            }
            #endif
            #if DEBUG
            // `ghostty_surface_read_text` takes the same internal surface lock as
            // `process_output`. Reading it on the MAIN thread per-output (to feed
            // the XCUITest accessibility label) contended that lock against the
            // off-main renderer/IO during a fast render storm and wedged the main
            // thread on libghostty's futex until the scene-update watchdog
            // (0x8BADF00D) froze the app. Read it HERE on the serial output queue
            // instead — already serialized with `process_output`, so the two are
            // never concurrent — throttled, and hand only the finished string to
            // main. Off-main reads can never trip the main-thread watchdog.
            var accessibilityText: String?
            let a11yNow = CACurrentMediaTime()
            if a11yNow - workQueue.lastAccessibilityTextTime > 0.5 {
                workQueue.lastAccessibilityTextTime = a11yNow
                accessibilityText = Self.accessibilitySurfaceText(surface)
            }
            #endif
            // Content-bottom measurement for the keyboard blank-space
            // absorption. Same off-main lock discipline and throttling as the
            // accessibility read above; only the row count crosses to main.
            var contentBottomRows: Int?
            let contentNow = CACurrentMediaTime()
            if contentNow - workQueue.lastContentBottomTime > contentMeasurementInterval {
                workQueue.lastContentBottomTime = contentNow
                // The viewport read is bounded by the visible screen (a few
                // KB at phone grid sizes), never scrollback; the cap is a
                // defensive guard against a pathological viewport.
                if let viewportText = Self.surfaceText(surface, pointTag: GHOSTTY_POINT_VIEWPORT),
                   viewportText.utf8.count <= 131_072 {
                    contentBottomRows = Self.contentRowCount(inViewportText: viewportText)
                }
            }
            DispatchQueue.main.async {
                guard let self, !self.isDismantled else {
                    completion?(true)
                    return
                }
                guard self.surfaceGeneration == generation else {
                    completion?(false)
                    return
                }
                self.consecutiveOutputTimeoutRecoveries = 0
                // The model is now newer, but its pixels are not visible yet.
                // Keep this distinction until the matching render-presented
                // callback so UIKit never scrolls ahead of the frame it shows.
                self.hasAppliedOutput = true
                self.needsDraw = true
                if let contentBottomRows {
                    if contentBottomRows != self.hostedContentBottomRowCount {
                        MobileDebugLog.anchormux(
                            "kb.contentRows \(self.hostedContentBottomRowCount.map(String.init) ?? "nil")->\(contentBottomRows)"
                        )
                    }
                    self.hostedContentBottomRowCount = contentBottomRows
                }
                self.scheduleVisibleArtifactCountUpdate()
                #if DEBUG
                self.lastOutputAppliedTime = CACurrentMediaTime()
                #endif
                if !self.surfaceHasReceivedOutput {
                    self.scrollInitialOutputToBottomIfNeeded()
                }
                let now = CACurrentMediaTime()
                if now - self.lastProcessOutputLogTime > 1.0 {
                    self.lastProcessOutputLogTime = now
                    if self.window != nil {
                        self.logLayerTree(reason: "processOutput")
                    }
                }
                #if DEBUG
                if let accessibilityText, !accessibilityText.isEmpty {
                    self.debugAccessibilityProxy.accessibilityLabel = accessibilityText
                }
                self.onOutputProcessedForTesting?()
                #endif
                completion?(true)
            }
        }
    }

    private func scrollInitialOutputToBottomIfNeeded() {
        guard shouldScrollInitialOutputToBottom, surface != nil else { return }
        shouldScrollInitialOutputToBottom = false
        guard !preservesUserViewportAnchor else { return }
        enqueueScrollToBottom()
    }

    /// Enqueues Ghostty's `scroll_to_bottom` binding action on the serial
    /// surface queue. `ghostty_surface_binding_action` takes the same internal
    /// surface lock as `process_output`/`render_now`; inline on MAIN it would
    /// contend that lock against the off-main renderer/IO during a render
    /// storm and wedge main on libghostty's futex (same dispatch pattern as
    /// `applyPendingFontSizeIfNeeded`). Coalesced: one pending snap is enough
    /// because it runs after everything already queued, so key-repeat during a
    /// stall never fans out into one lock-taking queue item per event.
    func enqueueScrollToBottom() {
        // The bottom snap resets Ghostty's fractional pixel offset; drop the
        // pixel batch, remainder, and held position so the next gesture
        // rebases from the bottom.
        pendingScrollPixels = 0
        pendingLocalScrollPixels = 0
        pendingLocalPixelScrollInteractionGeneration = nil
        pendingLocalPixelScrollReassert = false
        localPixelScrollState.withLock {
            $0.epoch &+= 1
            $0.remainderPx = 0
            $0.lastApplied = nil
            $0.topRevealPx = 0
        }
        let interactionGeneration = recordFollowBottomInteraction()
        scrollToBottomInteractionGeneration = interactionGeneration
        if !scrollToBottomRequested && !scrollToBottomInFlight {
            scrollToBottomRetryCount = 0
            scrollToBottomRetryAt = nil
        }
        scrollToBottomRequested = true
        pumpScrollToBottomIfNeeded()
    }

    /// True while a non-blocking prompt-reveal operation is queued or running
    /// on the serial surface queue.
    var scrollToBottomInFlight = false
    /// Generation of the current follow-bottom intent. A user scroll clears
    /// this token, invalidating queued or in-flight prompt reveal work.
    var scrollToBottomInteractionGeneration: UInt64?
    /// Coalesced prompt-reveal work. A busy renderer mutex leaves this set and
    /// the display link retries it on a later frame; no output operation waits
    /// behind an unbounded Ghostty binding action.
    var scrollToBottomRequested = false
    /// Number of failed try-only attempts in the current prompt-reveal episode.
    var scrollToBottomRetryCount: UInt8 = 0
    /// Earliest display-link time at which the next try-only attempt may run.
    var scrollToBottomRetryAt: CFTimeInterval?

    private func pumpScrollToBottomIfNeeded() {
        guard scrollToBottomRequested,
              !scrollToBottomInFlight,
              !renderingSuspended,
              !isDismantled,
              let surface else { return }
        if let retryAt = scrollToBottomRetryAt,
           CACurrentMediaTime() < retryAt {
            return
        }
        scrollToBottomRetryAt = nil
        scrollToBottomRequested = false
        scrollToBottomInFlight = true
        let generation = surfaceGeneration
        let interactionGeneration = scrollToBottomInteractionGeneration
            ?? viewportRestoreGate.withLock { $0.interactionGeneration }
        let gate = viewportRestoreGate
        outputQueue.async { [weak self] in
            // This C entry point is deliberately try-only. A false result is
            // ordinary under a PTY burst, so the main actor keeps the request
            // coalesced and retries it from the next display-link tick.
            let applied = ghostty_surface_try_scroll_to_bottom(surface)
            if applied {
                gate.withLock {
                    $0.appliedInteractionGeneration = max(
                        $0.appliedInteractionGeneration,
                        interactionGeneration
                    )
                }
            }
            DispatchQueue.main.async {
                // Generation-guarded like the process-output completion: a
                // stale pre-recovery completion must not mutate a new queue's
                // request state.
                guard let self, self.surfaceGeneration == generation else { return }
                self.scrollToBottomInFlight = false
                guard self.scrollToBottomInteractionGeneration == interactionGeneration else {
                    self.needsDraw = true
                    return
                }
                if !applied {
                    if self.scrollToBottomRetryCount >= Self.maximumScrollToBottomRetries {
                        self.scrollToBottomRequested = false
                        self.scrollToBottomRetryAt = nil
                        MobileDebugLog.anchormux("scroll_to_bottom.retry_exhausted")
                    } else {
                        self.scrollToBottomRetryCount &+= 1
                        let exponent = min(Int(self.scrollToBottomRetryCount) - 1, 3)
                        let multiplier = 1 << max(exponent, 0)
                        let delay = min(
                            Self.scrollToBottomRetryMaximumDelay,
                            Self.scrollToBottomRetryBaseDelay * CFTimeInterval(multiplier)
                        )
                        self.scrollToBottomRetryAt = CACurrentMediaTime() + delay
                        self.scrollToBottomRequested = true
                    }
                    self.needsDraw = true
                } else {
                    self.scrollToBottomRetryCount = 0
                    self.scrollToBottomRetryAt = nil
                    self.needsDraw = true
                    self.scheduleVisibleArtifactCountUpdate()
                }
            }
        }
    }

    static func forwardDaemonOutputBytes(_ data: Data) -> Data {
        // The daemon owns terminal byte semantics. iOS must feed Ghostty the
        // exact VT stream it received so desktop and mobile render the same
        // session history and prompt state.
        data
    }

    @objc
    func focusInput() {
        requestTerminalInputFocus()
    }

    private func requestTerminalInputFocus() {
        onFocusInputRequestedForTesting?()
        synchronizeActualInputOwner()
        inputSession.send(
            keyboardVisible
                ? .requestFocus(.terminal)
                : .requestVisibleFocus(.terminal)
        )
    }

    /// Requests the hosted composer through the same responder owner as terminal taps.
    public func requestComposerInputFocus() {
        synchronizeActualInputOwner()
        inputSession.send(
            keyboardVisible
                ? .requestFocus(.composer)
                : .requestVisibleFocus(.composer)
        )
    }

    /// Mirrors the SwiftUI field's user-driven responder changes into the owner.
    public func composerInputFocusChanged(_ isFirstResponder: Bool) {
        inputSession.send(
            .responderChanged(owner: .composer, isFirstResponder: isFirstResponder)
        )
    }

    /// Clears current intent and resigns before the Photos picker starts presenting.
    public func photoPickerWillPresent() {
        synchronizeActualInputOwner()
        inputSession.send(.modalWillPresent)
    }

    /// Records the PhotosPicker binding's presented edge.
    public func photoPickerDidPresent() {
        inputSession.send(.modalDidPresent)
    }

    /// Reconciles any focus request retained while the picker was on screen.
    public func photoPickerDidDismiss() {
        inputSession.send(.modalDidDismiss)
    }

    private func performInputFocus(_ owner: TerminalInputOwner) -> Bool {
        guard window != nil,
              !isDismantled,
              UIApplication.shared.applicationState == .active else {
            return false
        }

        switch owner {
        case .terminal:
            setNeedsGeometrySync()
            inputProxy.updateAccessoryLayoutInsets()
            // The keyboard toggle no longer rides inputAccessoryView, so
            // reloading input views here only forces UIKit to re-evaluate the
            // keyboard mid-transition and can snap the reveal on iOS 27.
            let alreadyFocused = inputProxy.isFirstResponder
            let becameFocused = alreadyFocused || inputProxy.becomeFirstResponder()
            return becameFocused
        case .composer:
            guard composerActive else { return false }
            composerContainer.layoutIfNeeded()
            guard let input = composerContainer.firstFocusableTextInputInSubtree() else {
                return false
            }
            // Same rule for the composer field, the show path should be a
            // straight responder handoff, not a keyboard view reload.
            let alreadyFocused = input.isFirstResponder
            let becameFocused = alreadyFocused || input.becomeFirstResponder()
            return becameFocused
        }
    }

    private func performInputResign(_ owner: TerminalInputOwner) -> Bool {
        let responder: UIView?
        switch owner {
        case .terminal:
            responder = inputProxy.isFirstResponder ? inputProxy : nil
        case .composer:
            responder = composerContainer.firstResponderInSubtree()
        }
        guard let responder else { return true }
        return responder.resignFirstResponder() || !responder.isFirstResponder
    }

    private func inputActualOwnerDidChange(_ owner: TerminalInputOwner?) {
        if owner != nil {
            Self.activeInputSurface = self
        } else if Self.activeInputSurface === self {
            Self.activeInputSurface = nil
        }
    }

    private func synchronizeActualInputOwner() {
        let observedOwner: TerminalInputOwner?
        if inputProxy.isFirstResponder {
            observedOwner = .terminal
        } else if composerContainer.firstResponderInSubtree() != nil {
            observedOwner = .composer
        } else {
            observedOwner = nil
        }

        if let actualOwner = inputSession.state.actualOwner,
           actualOwner != observedOwner {
            inputSession.send(
                .responderChanged(owner: actualOwner, isFirstResponder: false)
            )
        }
        if let observedOwner,
           inputSession.state.actualOwner != observedOwner {
            inputSession.send(
                .responderChanged(owner: observedOwner, isFirstResponder: true)
            )
        }
    }

    /// Resigns the currently focused terminal input proxy, if any.
    ///
    /// Use before presenting SwiftUI chrome over the terminal so UIKit releases
    /// the hidden text input and the terminal can recalculate full-height
    /// geometry after the keyboard leaves.
    public static func resignActiveInput() {
        activeInputSurface?.resignCurrentInput()
    }

    /// Resigns whichever input currently owns this surface's software keyboard.
    ///
    /// The terminal proxy and the hosted composer field are siblings, so neither
    /// subtree can release the other. Modal presentations must call this before
    /// presenting: UIKit can otherwise hide the keyboard while leaving the proxy
    /// first responder, and a later terminal tap cannot trigger another focus
    /// transition because the proxy already reports itself focused.
    public func resignCurrentInput() {
        synchronizeActualInputOwner()
        inputSession.send(.releaseFocus)
    }

    /// Resigns this surface's hidden text input.
    public func resignInput() {
        resignCurrentInput()
        // Dock geometry follows the OS-selected source; responder release only
        // decides whether UIKit should dismiss the software keyboard.
    }

    /// Stops user-visible and accessibility output from a surface SwiftUI has removed.
    public func prepareForDismantle() {
        isDismantled = true
        // Block-based observers stay registered (and their closures retained
        // by NotificationCenter) until explicitly removed; dropping the token
        // array alone would leak a registration per surface remount.
        for token in artifactChipAccessibilityObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        artifactChipAccessibilityObserverTokens.removeAll()
        prepareForReuseAfterDetach()
    }

    /// Quiesces the surface on window detach: resigns input, stops the display
    /// link, drops focus, and removes the debug accessibility carrier from the
    /// tree. Does not set ``isDismantled`` so a transient detach can re-attach
    /// and resume; only ``prepareForDismantle()`` marks the surface dead.
    private func prepareForReuseAfterDetach() {
        clearVerifiedReplayPresentation()
        visibleArtifactCountTask?.cancel()
        visibleArtifactCountTask = nil
        visibleArtifactCountSettleFrames = nil
        visibleArtifactSnapshotGeneration &+= 1
        lastVisibleArtifactSnapshotText = nil
        lastVisibleArtifactSnapshotColumns = nil
        lastVisibleArtifactSnapshotGeneration = nil
        lastReportedVisibleArtifactCount = 0
        delegate?.ghosttySurfaceViewDidResetArtifactCount(self)
        artifactChipHost.setContent(nil)
        resetArtifactChipReveal()
        updateArtifactChipVisibility(animated: false)
        resetScrollStateForSurfaceReplacement()
        completePendingSurfaceOperations(returning: false)
        cancelRenderPipelineRecoveryResumeTimer()
        renderPipelineRecoveryPaused = false
        renderPipelineRecoveryPausedAt = nil
        renderInFlight = false
        renderInFlightSince = nil
        renderReplacementInFlight = false
        needsAnotherRender = false
        pendingRenderRetryCount = 0
        renderPresentationGate.reset()
        renderSubmission = nil
        pendingRenderSubmission = nil
        hasAppliedOutput = false
        surfaceHasReceivedOutput = false
        inputSession.send(.surfaceDetached)
        stopDisplayLink()
        setFocus(false)
        #if DEBUG
        debugAccessibilityProxy.accessibilityLabel = nil
        debugAccessibilityProxy.isAccessibilityElement = false
        #endif
    }

    func simulateTextInputForTesting(_ text: String) {
        setFocus(true)
        sendText(text)
        runtime?.tick()
    }

    func simulatePasteInputForTesting(_ text: String) {
        setFocus(true)
        sendPaste(text)
        runtime?.tick()
    }

    func simulateInputProxyTextChangeForTesting(_ text: String, isComposing: Bool) {
        setFocus(true)
        inputProxy.simulateTextChangeForTesting(text, isComposing: isComposing)
        runtime?.tick()
    }

    func renderedTextForTesting(pointTag: ghostty_point_tag_e = GHOSTTY_POINT_VIEWPORT) -> String? {
        guard let surface else { return nil }

        let topLeft = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return nil
        }
        defer {
            ghostty_surface_free_text(surface, &text)
        }

        guard let ptr = text.text, text.text_len > 0 else {
            return ""
        }

        let data = Data(bytes: ptr, count: Int(text.text_len))
        return String(decoding: data, as: UTF8.self)
    }

    #if DEBUG
    func accessibilityRenderedTextForTesting() -> String? {
        let candidates = [
            renderedTextForTesting(pointTag: GHOSTTY_POINT_SURFACE),
            renderedTextForTesting(pointTag: GHOSTTY_POINT_SCREEN),
            renderedTextForTesting(pointTag: GHOSTTY_POINT_ACTIVE),
            renderedTextForTesting(pointTag: GHOSTTY_POINT_VIEWPORT),
        ].compactMap { $0 }

        return candidates.max { lhs, rhs in
            lhs.utf8.count < rhs.utf8.count
        }
    }

    /// Off-main equivalent of ``accessibilityRenderedTextForTesting()`` that
    /// reads via the raw surface handle so it can run on the serial output queue
    /// (alongside `process_output`) instead of the main thread. See the call
    /// site in `processOutput` for why a main-thread read deadlocks the watchdog.
    nonisolated static func accessibilitySurfaceText(_ surface: ghostty_surface_t) -> String? {
        let candidates = [
            surfaceText(surface, pointTag: GHOSTTY_POINT_SURFACE),
            surfaceText(surface, pointTag: GHOSTTY_POINT_SCREEN),
            surfaceText(surface, pointTag: GHOSTTY_POINT_ACTIVE),
            surfaceText(surface, pointTag: GHOSTTY_POINT_VIEWPORT),
        ].compactMap { $0 }
        return candidates.max { $0.utf8.count < $1.utf8.count }
    }

    #endif

    /// Read the surface text for `pointTag` from the raw handle. Pure libghostty
    /// C calls, safe to run off the main actor on the serial output queue.
    ///
    /// Intentionally not `#if DEBUG`-gated: the non-DEBUG, release-shipping
    /// ``visibleTerminalSnapshot()`` (Copy Debug Logs) calls this, so gating it
    /// out breaks the Release/TestFlight archive while compiling fine in Debug.
    nonisolated static func surfaceText(_ surface: ghostty_surface_t, pointTag: ghostty_point_tag_e) -> String? {
        let topLeft = ghostty_point_s(tag: pointTag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        let bottomRight = ghostty_point_s(tag: pointTag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        let selection = ghostty_selection_s(top_left: topLeft, bottom_right: bottomRight, rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return "" }
        return String(decoding: Data(bytes: ptr, count: Int(text.text_len)), as: UTF8.self)
    }

    func copyableTextForCurrentSurface(surface expectedSurface: ghostty_surface_t) async -> String? {
        let generation = surfaceGeneration
        guard surface == expectedSurface,
              !isDismantled,
              !renderPipelineRecoveryPaused,
              !renderingSuspended else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            let operationID = makeSurfaceOperationID()
            if let existing = pendingCopyableTextRead {
                pendingCopyableTextRead = nil
                existing.cancel()
                existing.continuation.resume(returning: nil)
            }
            let cancellation = SurfaceOperationCancellationToken()
            pendingCopyableTextRead = PendingCopyableTextRead(
                id: operationID,
                startedAt: CACurrentMediaTime(),
                cancellation: cancellation,
                continuation: continuation
            )
            ensureSurfaceOperationDeadlinePump()
            let read = CopyableTextRead(
                surface: expectedSurface,
                generation: generation,
                cancellation: cancellation
            )
            outputQueue.async { [weak self] in
                guard !read.cancellation.isCancelled else { return }
                // SCREEN = scrollback + all written rows. Fall back to the
                // viewport-only read if the screen read fails outright.
                let screenText = Self.surfaceText(read.surface, pointTag: GHOSTTY_POINT_SCREEN)
                guard !read.cancellation.isCancelled else { return }
                let text = screenText ?? Self.surfaceText(read.surface, pointTag: GHOSTTY_POINT_VIEWPORT)
                guard !read.cancellation.isCancelled else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.surface == read.surface,
                          self.surfaceGeneration == read.generation else {
                        self.completePendingCopyableTextRead(id: operationID, returning: nil)
                        return
                    }
                    self.completePendingCopyableTextRead(id: operationID, returning: text)
                }
            }
        }
    }

    func renderedHTMLForTesting(pointTag: ghostty_point_tag_e = GHOSTTY_POINT_VIEWPORT) -> String? {
        _ = pointTag
        // ghostty_surface_read_text_html not available in this build
        return nil
    }

    func processExitedForTesting() -> Bool {
        guard let surface else { return false }
        return ghostty_surface_process_exited(surface)
    }

    func disposeSurface() {
        stopDisplayLink()
        cancelRenderPipelineRecoveryResumeTimer()
        resetScrollStateForSurfaceReplacement()
        guard let surface else { return }
        GhosttySurfaceView.unregister(surface: surface)
        self.surface = nil
        let currentBridge = bridge
        let currentQueue = outputQueue
        currentBridge.detach()
        // Free on the SAME serial `outputQueue` that runs `process_output`,
        // `render_now`, and `binding_action` (all of which capture this C
        // surface pointer), not a separate queue. FIFO ordering guarantees the
        // free runs after every already-enqueued block that captured the
        // pointer, so a dismantled/removed surface's queued libghostty work can
        // never use-after-free against the free, and no two of them ever touch
        // the surface concurrently. `processOutput`'s main-actor guard stops new
        // work from being enqueued once `surface` is nil, so only the bounded
        // backlog drains before the free. The host-owned bridge retain stays
        // alive until synchronous libghostty teardown has stopped callbacks.
        enqueueSurfaceFree(surface, generation: surfaceGeneration, on: currentQueue)
    }

    func enqueueSurfaceFree(
        _ surface: ghostty_surface_t,
        generation: UInt64, on queue: GhosttySurfaceWorkQueue,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        surfaceFreeDrainWatchdog.start(generation: generation) { [weak self] in self?.pendingSurfaceFreeCount ?? 0 }
        queue.async { [weak self] in
            let userdata = ghostty_surface_userdata(surface)
            ghostty_surface_free(surface)
            GhosttySurfaceBridge.releaseRetainedOpaque(userdata)
            Task { @MainActor in self?.surfaceFreeDrainWatchdog.cancel(generation: generation); completion?() }
        }
    }

    private var preferredScreenScale: CGFloat {
        if let screen = window?.windowScene?.screen {
            return screen.scale
        }

        let traitScale = traitCollection.displayScale
        return traitScale > 0 ? traitScale : 2
    }

    private func sendText(_ text: String) {
        guard let surface else { return }
        let normalized = text.replacingOccurrences(of: "\n", with: "\r")
        let count = normalized.utf8CString.count
        guard count > 1 else { return }
        normalized.withCString { pointer in
            ghostty_surface_text_input(surface, pointer, UInt(count - 1))
        }
    }

    private func sendPaste(_ text: String) {
        guard let surface else { return }
        let count = text.utf8CString.count
        guard count > 0 else { return }
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(count - 1))
        }
    }

    func initializeSurface() {
        guard let app = runtime?.app else { return }
        surface = makeSurface(app: app)
        if let surface {
            GhosttySurfaceView.register(surface: surface, for: self)
            appliedTerminalConfigTheme = nil
            applyTerminalConfigTheme()
            // A live C surface is not proof that its first pixels reached the
            // IOSurface layer. Keep the fallback visible until a tokened frame
            // is acknowledged by Ghostty.
            surfaceHasReceivedOutput = false
            hasAppliedOutput = false
        }
        setNeedsGeometrySync()
        startDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(target: self), selector: #selector(DisplayLinkProxy.handleDisplayLink))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        cursorRenderWakeState.start(now: CACurrentMediaTime())
        needsDraw = true
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Shared reaction to user-produced terminal input (typing, backspace,
    /// escape sequences, paste): restart Ghostty's cursor frame cadence and
    /// optimistically snap the local mirror to the bottom of scrollback. The
    /// mirror is display-only — the Mac echoes input at the prompt — so a user who types
    /// while scrolled up would otherwise keep looking at old scrollback and
    /// read the terminal as frozen. Passive output never forces this jump;
    /// only explicit user input does (plus the one-time initial-output scroll
    /// in `scrollInitialOutputToBottomIfNeeded`).
    private func handleUserProducedInput() {
        restartCursorRenderWake()
        // A flick still decelerating would fight the snap: deltas already in
        // `pendingScrollLines` flush on the display-link frame AFTER the snap
        // below, and UIScrollView momentum keeps producing more. Drop the
        // pending deltas and freeze the scroll mechanics at the current offset
        // (kill-deceleration idiom) so typed input lands at the bottom.
        pendingScrollLines = 0
        linePathFractionCarry = 0
        pendingScrollPixels = 0
        pendingScrollInteractionGeneration = nil
        pendingLocalScrollLines = 0
        pendingLocalScrollInteractionGeneration = nil
        pendingLocalScrollPixels = 0
        pendingLocalPixelScrollInteractionGeneration = nil
        scrollMechanicsView.setContentOffset(scrollMechanicsView.contentOffset, animated: false)
        enqueueScrollToBottom()
    }

    /// Request a frame now and restart the host cadence that gives Ghostty
    /// opportunities to advance its renderer-owned cursor blink phase.
    private func restartCursorRenderWake() {
        guard surface != nil else { return }
        cursorRenderWakeState.reset(now: CACurrentMediaTime())
        needsDraw = true
    }

    @objc func handleDisplayLinkFire() {
        let now = CACurrentMediaTime()
        if checkSurfaceOperationDeadlines(now: now) {
            return
        }
        // Prompt reveal is best-effort and try-only. Pump it once per frame so
        // a busy renderer mutex never turns typing into a queue-wide stall.
        pumpScrollToBottomIfNeeded()
        completePendingVerifiedReplayPresentationIfPresented()
        guard surface != nil else {
            if !hasPendingSurfaceOperationDeadline {
                stopDisplayLink()
            }
            return
        }
        #if DEBUG
        debugStepScrollScriptIfNeeded()
        debugRecordScrollFrameRateTick(now: now)
        #endif
        #if DEBUG
        // Main-thread liveness heartbeat + presented-surface state. Time-gated,
        // no behavior change. The `contents`/size fields let an IDLE blank be
        // classified without a fresh output/geometry event: contents=false ⇒
        // the IOSurface lost its frame and nothing re-triggered a draw (redraw
        // bug); contents=true while the screen looks blank ⇒ the render-grid
        // content itself is empty (sync/producer). `sinceOutput` ties a blank
        // to a render-grid stream gap or rules it out. CALayer reads only — no
        // libghostty call, so no futex/main-thread-wedge risk.
        let nowHeartbeat = now
        if nowHeartbeat - lastHeartbeatTime >= 2.0 {
            lastHeartbeatTime = nowHeartbeat
            let renderLayer = (layer.sublayers ?? []).first(where: { isGhosttyRendererLayer($0) })
            let renderSize = renderLayer?.bounds.size ?? .zero
            let sinceOutputMs = lastOutputAppliedTime > 0
                ? Int((nowHeartbeat - lastOutputAppliedTime) * 1000)
                : -1
            MobileDebugLog.anchormux(
                "tick.alive win=\(window != nil) suspended=\(renderingSuspended) "
                + "renderInFlight=\(renderInFlight) "
                + "needsDraw=\(needsDraw) contents=\(renderLayer?.contents != nil) "
                + "surf=\(Int(renderSize.width))x\(Int(renderSize.height)) "
                + "sinceOutput=\(sinceOutputMs)ms"
            )
        }
        #endif
        if let renderInFlightSince {
            let stalledMs = Int((now - renderInFlightSince) * 1000)
            if stalledMs >= Int(Self.renderPipelineStallDeadline * 1000),
               renderSubmission != nil,
               recoverRenderPipeline(
                   reason: "render_in_flight",
                   stalledMs: stalledMs,
                   replay: .delegateWhenNoCaller
               ) {
                return
            }
        }
        // Apply at most one coalesced zoom per frame. This only changes the
        // font; the geometry resync is deferred until zoom settles.
        let appliedZoom = applyPendingFontSizeIfNeeded()
        // Post-zoom geometry resync: once no new zoom target has landed for a
        // few quiet frames, do ONE resize to re-pin the letterbox at the
        // settled font. This is the single geometry change per zoom gesture
        // instead of one per step (which thrashed the IOSurface and wedged the
        // render queue).
        if !appliedZoom, var frames = zoomSettleFrames {
            frames -= 1
            if frames <= 0 {
                zoomSettleFrames = nil
                setNeedsGeometrySync()
            } else {
                zoomSettleFrames = frames
            }
        }
        sampleHostedKeyboardPresentation()
        // Apply geometry at most once per frame. Every trigger (resize, zoom,
        // keyboard, effective-grid pin) only marks `needsGeometrySync`, so a
        // fast pinch can no longer drive a synchronous per-event storm of
        // set_size calls (the source of the jumbled grid + renderer overload).
        if needsGeometrySync {
            needsGeometrySync = false
            let reassert = pendingGeometryReassert
            pendingGeometryReassert = false
            syncSurfaceGeometry(shouldReassertNaturalSize: reassert)
        }
        let cursorRenderWakeDue = cursorRenderWakeState.consumeWakeIfDue(now: now)
        // Draw on content changes, Ghostty cursor wake-ups, and for a short
        // bounded burst after any geometry change. iOS has no renderer-side vsync, so a frame is
        // only produced when we ask. The renderer draws at the layer size read
        // at draw time and presents a frame behind, so a single post-resize
        // draw can land while the layer is still mid-animation, leaving a
        // stale, wrong-size surface on screen (the blank / crushed-strip
        // garble). Requesting a few extra frames after the geometry settles
        // guarantees a draw at the final size. It is bounded (not a perpetual
        // loop) so it never floods the main queue with `setSurface` present
        // blocks, which made the app unresponsive.
        let geometrySettling = pendingRenderFrames > 0
        if geometrySettling { pendingRenderFrames -= 1 }
        if needsDraw || cursorRenderWakeDue || geometrySettling {
            needsDraw = false
            // Keep the dirty bit when the surface cannot accept a submission.
            // A replay can hold the presentation gate while a scroll or output
            // update arrives. Clearing this bit before the gate accepts work
            // loses that update until an unrelated event requests a frame.
            if !requestRender() {
                needsDraw = true
            }
        }

        // Report the settled natural grid to the Mac once it has stopped
        // changing. `applyGeometryResult` resets the counter on every grid
        // change, so this only fires after the attach/keyboard/zoom settle —
        // one PTY resize instead of one per intermediate size.
        //
        // While a zoom is still in progress (`zoomSettleFrames` armed = a zoom
        // landed within the last few frames) HOLD the report entirely. Each
        // zoom step changes the natural grid; reporting mid-zoom makes the Mac
        // resize the PTY over and over, so a full-screen TUI (a coding agent,
        // vim, etc.) redraws at constantly-changing sizes and garbles into the
        // "bad intermediate state". Zoom is a LOCAL font change; the shared
        // grid should renegotiate exactly once, after the user settles.
        if let pending = pendingViewportReport {
            if zoomSettleFrames != nil {
                viewportReportSettleFrames = 0
            } else {
                viewportReportSettleFrames += 1
                if viewportReportSettleFrames >= Self.viewportReportSettleThreshold {
                    pendingViewportReport = nil
                    viewportReportSettleFrames = 0
                    viewportReportID &+= 1
                    awaitingViewportEcho = true
                    MobileDebugLog.anchormux("zoom.report grid=\(pending.columns)x\(pending.rows) id=\(viewportReportID)")
                    delegate?.ghosttySurfaceView(self, didResize: pending, reportID: viewportReportID)
                }
            }
        }

        // Flush coalesced scroll to the Mac at most once per frame.
        flushPendingScrollIfNeeded()

        // Visible artifact detection shares the viewport report's quiet-frame
        // cadence. Output/scroll/geometry only re-arm this counter; one visible
        // snapshot is read after eight quiet frames, never per render frame or
        // per output chunk.
        if var settleFrames = visibleArtifactCountSettleFrames {
            if zoomSettleFrames != nil {
                visibleArtifactCountSettleFrames = 0
            } else {
                settleFrames += 1
                if settleFrames >= Self.viewportReportSettleThreshold {
                    visibleArtifactCountSettleFrames = nil
                    refreshVisibleArtifactCount()
                } else {
                    visibleArtifactCountSettleFrames = settleFrames
                }
            }
        }

        // Fade the zoom HUD once interaction has been quiet. Uses real elapsed
        // time off the continuous display link (no timer / sleep).
        if zoomOverlayShown,
           now - zoomOverlayLastInteraction > Self.zoomOverlayVisibleDuration {
            fadeOutZoomOverlay()
        }
    }

    /// Drive one render through the surface's presentation gate.
    ///
    /// On iOS libghostty's renderer-thread event loop does not pump frames
    /// (it's a platform-display-driven embedder), so `ghostty_surface_refresh`
    /// — which only wakes that loop — never produces a frame: `updateFrame`
    /// doesn't run, the cell grid stays 0x0, and the surface renders blank
    /// (uninitialized buffer shows as garbled). `render_now` instead runs
    /// `applyPendingResizeIfNeeded` + drainMailbox + `updateFrame` + drawFrame
    /// directly on the calling thread, so the terminal grid is sized and the
    /// cells are rebuilt from real content. We run it on `outputQueue` so the
    /// GPU encode/swap-chain wait stays OFF the main thread (calling it on main
    /// is what tripped the scene-update watchdog under fast zoom). The present
    /// still hops to main inside libghostty (`setSurface`). The display link
    /// gates this on `needsDraw`/`pendingRenderFrames`, so it is not a
    /// per-frame loop that would flood the main queue with present blocks.
    @discardableResult
    private func requestRender(
        presentationRetryCount: UInt8 = 0
    ) -> Bool {
        // Never dispatch a render into the background: a backgrounded
        // `render_now` can stall acquiring a swap-chain frame slot from
        // libghostty, leaving the serial output queue undrained. The acquire is
        // now bounded in libghostty (so a foreground stall self-heals as a
        // skipped frame the display link re-drives), but we still gate on
        // suspension; `resumeRendering` clears it on the next active transition.
        guard !renderPipelineRecoveryPaused,
              !renderingSuspended,
              !isRenderDispatchSuppressed,
              let surface,
              !isDismantled else { return false }
        // Replay suppression is enforced by the presentation gate, not by
        // dropping the request here. Ordinary and local-scroll submissions
        // remain pending and become eligible when the frozen replay is
        // revealed.
        return enqueueRenderSubmission(
            RenderSubmission(
                token: makeSurfaceOperationID(),
                generation: surfaceGeneration,
                kind: .ordinary,
                surface: surface,
                verifiedReplayRead: nil,
                presentationRetryCount: presentationRetryCount
            )
        )
    }

    /// Queues a frame behind the currently presented frame. Every producer uses
    /// this path, so a model update and a local scroll cannot publish separate
    /// layer assignments in the same presentation window.
    @discardableResult
    func enqueueRenderSubmission(_ submission: RenderSubmission) -> Bool {
        guard surface == submission.surface,
              surfaceGeneration == submission.generation,
              !isDismantled else { return false }
        let action = renderPresentationGate.enqueue(submission.ticket)
        switch action {
        case .started:
            guard startRenderSubmission(submission) else {
                repairRenderAdmissionAfterFailedStart()
                return false
            }
            return true
        case .queued:
            if shouldReplacePendingRenderSubmission(with: submission) {
                pendingRenderSubmission = submission
            }
            // Queue admission, including an ordinary frame coalesced behind a
            // pending replay, is successful. The gate transition that removes
            // suppression will promote retained work; returning false here
            // would keep `needsDraw` hot and retry this request every frame.
            return true
        case .ignored, .idle:
            return false
        }
    }

    private func shouldReplacePendingRenderSubmission(
        with submission: RenderSubmission
    ) -> Bool {
        guard let pendingRenderSubmission else { return true }
        return pendingRenderSubmission.kind != .verifiedReplay
            || submission.kind == .verifiedReplay
    }

    /// Replaces the current token when a geometry pass invalidates its
    /// IOSurface target. Ghostty serializes the replacement behind the old
    /// render on `outputQueue`; the old callback is stale by token and cannot
    /// release the replacement gate.
    @discardableResult
    func replaceInFlightRenderSubmission(
        with replacement: RenderSubmission
    ) -> Bool {
        guard let current = renderSubmission,
              current.generation == replacement.generation,
              current.surface == replacement.surface,
              renderPresentationGate.inFlight == current.ticket,
              renderPresentationGate.replaceInFlight(with: replacement.ticket)
                == .started(replacement.ticket) else {
            return false
        }
        renderSubmission = nil
        renderInFlight = false
        renderInFlightSince = nil
        guard startRenderSubmission(replacement) else {
            repairRenderAdmissionAfterFailedStart()
            return false
        }
        return true
    }

    @discardableResult
    private func startRenderSubmission(_ submission: RenderSubmission) -> Bool {
        guard renderSubmission == nil,
              renderPresentationGate.inFlight == submission.ticket,
              surface == submission.surface,
              surfaceGeneration == submission.generation,
              !isDismantled else { return false }
        // A verified replay's callback is only meaningful after its exact
        // readback/presentation fence has been registered on MainActor. Keep
        // this admission edge next to the output-queue dispatch so a replay
        // can never submit a token that has no fence waiting for it.
        if submission.kind == .verifiedReplay,
           pendingVerifiedReplayPresentation?.id != submission.token {
            MobileDebugLog.anchormux(
                "verified_replay.admission_rejected reason=fence_missing"
            )
            return false
        }
        renderSubmission = submission
        renderInFlight = true
        renderInFlightSince = CACurrentMediaTime()
        let enqueuedAt = CACurrentMediaTime()
        let workQueue = outputQueue
        workQueue.async { [weak self] in
            let lagMs = (CACurrentMediaTime() - enqueuedAt) * 1000
            if lagMs > 150 { MobileDebugLog.anchormux("oq.render.LAG \(Int(lagMs))ms") }
            switch submission.kind {
            case .ordinary, .localScroll:
                #if DEBUG
                let renderStartedAt = CACurrentMediaTime()
                #endif
                ghostty_surface_render_now_with_token(submission.surface, submission.token)
                #if DEBUG
                // Scroll-smoothness audit: the draw shares this serial queue
                // with VT applies and scroll batches, so a slow frame
                // stretches everything behind it.
                let renderMs = (CACurrentMediaTime() - renderStartedAt) * 1000
                if renderMs > 8 {
                    let perfNow = CACurrentMediaTime()
                    if perfNow - workQueue.lastRenderPerfLogTime >= 0.25 {
                        workQueue.lastRenderPerfLogTime = perfNow
                        MobileDebugLog.anchormux(
                            "perf.render_now ms=\(Int(renderMs)) kind=\(String(describing: submission.kind))"
                        )
                    }
                }
                #endif
            case .verifiedReplay:
                guard let read = submission.verifiedReplayRead else {
                    ghostty_surface_render_now_with_token(
                        submission.surface,
                        submission.token
                    )
                    return
                }
                // Register the exported grid on MainActor before submitting
                // the token. The Ghostty callback may be synchronous, so do
                // not submit until the observation task has installed the
                // readback on the exact pending fence. Otherwise a callback
                // can win the race and release a token whose verification has
                // not been registered yet.
                let observed = read.exportGridSynchronously()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.acceptVerifiedReplayObservedFrame(
                        observed,
                        submission: VerifiedReplayRenderSubmission(
                            surface: submission.surface,
                            token: submission.token
                        ),
                        generation: submission.generation
                    ) else {
                        self.cancelRenderSubmission(token: submission.token)
                        return
                    }
                    // The read-back is now installed on the pending fence.
                    // Keep the gate occupied until Ghostty presents this
                    // exact token and the callback verifies its layer.
                    guard self.renderSubmission?.token == submission.token,
                          self.surface == submission.surface,
                          self.surfaceGeneration == submission.generation,
                          !self.isDismantled else { return }
                    self.outputQueue.async { [weak self] in
                        guard self != nil else { return }
                        ghostty_surface_render_now_with_token(
                            submission.surface,
                            submission.token
                        )
                    }
                }
            }
        }
        return true
    }

    /// Repairs the admission edge when the reducer accepted a ticket but the
    /// matching UIKit payload could not be started. Leaving that ticket in the
    /// reducer would make every later render queue behind a frame that can no
    /// longer produce a callback.
    private func repairRenderAdmissionAfterFailedStart() {
        resetRenderAdmissionStatePreservingSuppression()
        renderSubmission = nil
        pendingRenderSubmission = nil
        renderInFlight = false
        renderInFlightSince = nil
        renderReplacementInFlight = false
        needsAnotherRender = false
        pendingRenderRetryCount = 0
        needsDraw = true
        MobileDebugLog.anchormux("render.gate.admission_repaired")
    }

    /// Clears an invalid token without accidentally thawing a verified replay
    /// that is still holding the last-good presentation above the live layer.
    func resetRenderAdmissionStatePreservingSuppression() {
        let preserveSuppression = verifiedReplayRenderSuppressed
            || renderPresentationGate.isSuppressed
        renderPresentationGate.reset()
        renderReplacementInFlight = false
        if preserveSuppression {
            _ = renderPresentationGate.setSuppressed(true)
        }
    }

    /// Called only from the render-presented bridge callback. A stale callback
    /// cannot release the gate or advance fallback visibility.
    func finishRenderSubmission(token: UInt64) {
        releaseRenderSubmission(token: token, presented: true)
    }

    /// Called when Ghostty can prove that a tokened target was discarded or
    /// failed before reaching the host layer. Resolve the token immediately so
    /// one bad IOSurface cannot hold every later output frame behind a timeout.
    func handleRenderSubmissionFailure(
        token: UInt64,
        status: ghostty_render_presentation_status_e
    ) {
        guard let submission = renderSubmission,
              submission.token == token,
              submission.generation == surfaceGeneration else {
            return
        }
        MobileDebugLog.anchormux(
            "render.submission.failed token=\(token) kind=\(submission.kind) "
            + "status=\(status.rawValue)"
        )

        if submission.kind == .verifiedReplay,
           handleVerifiedReplayRenderFailure(token: token, status: status) {
            // A discarded replay was replaced with a fresh token while the
            // presentation gate stayed occupied. The stale callback cannot
            // release the replacement because its token no longer matches.
            return
        }
        if status == GHOSTTY_RENDER_PRESENTATION_DISCARDED,
           restartInFlightRenderSubmissionForCurrentGeometry(countsAsRetry: true) {
            return
        }

        let nextRetryCount = submission.presentationRetryCount &+ 1
        guard nextRetryCount <= Self.maximumRenderPresentationRetries else {
            // A persistent renderer rejection needs a fresh surface and
            // authoritative replay, not another ordinary token with a reset
            // counter. This is the terminal recovery edge for the episode.
            needsAnotherRender = false
            pendingRenderRetryCount = 0
            let stalledMs = renderInFlightSince.map {
                Int((CACurrentMediaTime() - $0) * 1000)
            } ?? 0
            let recovered = recoverRenderPipeline(
                reason: "render_submission_retry_exhausted",
                stalledMs: stalledMs,
                replay: .callerWillRequestReplay
            )
            if recovered {
                delegate?.ghosttySurfaceViewDidResetRenderPipeline(self)
            } else {
                cancelRenderSubmission(token: token)
            }
            return
        }

        // Carry the failure episode into the one follow-up submission. The
        // pending replay continuation, if any, has already been completed
        // above.
        pendingRenderRetryCount = nextRetryCount
        needsDraw = true
        needsAnotherRender = true
        pendingRenderFrames = max(pendingRenderFrames, 1)
        cancelRenderSubmission(token: token)
    }

    /// Releases a submission that failed before Ghostty could present it.
    func cancelRenderSubmission(token: UInt64) {
        releaseRenderSubmission(token: token, presented: false)
    }

    private func releaseRenderSubmission(token: UInt64, presented: Bool) {
        guard let submission = renderSubmission,
              submission.token == token,
              submission.generation == surfaceGeneration else { return }
        // The disposition for a replacement is now authoritative. Any
        // geometry changes coalesced while it was in flight can request one
        // follow-up frame below, after this operation has left the queue.
        renderReplacementInFlight = false
        let action = presented
            ? renderPresentationGate.complete(
                token: token,
                generation: submission.generation
            )
            : renderPresentationGate.cancel(
                token: token,
                generation: submission.generation
            )
        guard action != .ignored else { return }
        renderSubmission = nil
        renderInFlight = false
        renderInFlightSince = nil
        // A verified replay can be the first frame on a cold mount. It carries
        // valid terminal pixels even when no raw output chunk has arrived, so
        // it must also retire the snapshot fallback overlay.
        if presented && (hasAppliedOutput || submission.kind == .verifiedReplay) {
            surfaceHasReceivedOutput = true
            snapshotFallbackView.isHidden = true
        }
        #if DEBUG
        if let surfaceID = hostSurfaceID {
            if let sequence = latencyLastAppliedSequence {
                MobileLatencyTrace.stamp(
                    presented ? "rd.present" : "rd.cancel",
                    "s=\(surfaceID.prefix(8).lowercased()) seq=\(sequence)"
                )
            } else {
                MobileLatencyTrace.stamp(
                    presented ? "rd.present" : "rd.cancel",
                    "s=\(surfaceID.prefix(8).lowercased())"
                )
            }
        }
        #endif
        guard !isDismantled else {
            pendingRenderSubmission = nil
            needsAnotherRender = false
            pendingRenderRetryCount = 0
            return
        }
        if case .started(_) = action {
            if startPromotedRenderSubmission(action) {
                pendingRenderRetryCount = 0
                return
            }
        }
        if needsAnotherRender {
            let retryCount = pendingRenderRetryCount
            pendingRenderRetryCount = 0
            needsAnotherRender = false
            if !requestRender(presentationRetryCount: retryCount) {
                needsDraw = true
            }
        }
    }

    /// Starts the payload corresponding to a gate promotion, or repairs the
    /// gate if its metadata outlived the UIKit payload. The latter is a
    /// defensive boundary: leaving a promoted ticket in flight without a
    /// ``RenderSubmission`` makes every later frame queue forever.
    @discardableResult
    private func startPromotedRenderSubmission(
        _ action: TerminalRenderPresentationGateAction
    ) -> Bool {
        guard case .started(let ticket) = action else { return false }
        guard let pending = pendingRenderSubmission,
              pending.ticket == ticket else {
            MobileDebugLog.anchormux(
                "render.gate.promotion_payload_missing token=\(ticket.token)"
            )
            pendingRenderSubmission = nil
            resetRenderAdmissionStatePreservingSuppression()
            needsAnotherRender = false
            pendingRenderRetryCount = 0
            needsDraw = true
            return false
        }
        // A failed in-flight ordinary frame may have left its retry episode in
        // pendingRenderRetryCount. Carry that episode into a promoted ordinary
        // or local-scroll frame instead of silently restarting at zero. Replay
        // submissions have their own bounded retry accounting and should not
        // inherit an ordinary-frame count.
        let promoted: RenderSubmission
        if pending.kind == .verifiedReplay {
            promoted = pending
        } else {
            promoted = pending.withPresentationRetryCount(
                max(pending.presentationRetryCount, pendingRenderRetryCount)
            )
        }
        pendingRenderSubmission = nil
        pendingRenderRetryCount = 0
        guard startRenderSubmission(promoted) else {
            repairRenderAdmissionAfterFailedStart()
            return false
        }
        return true
    }

    /// Restarts the queued non-replay frame once the frozen presentation is
    /// removed. This is also used when a replay completion resumes an output
    /// frame that arrived while suppression was active.
    func resumeQueuedRenderAfterReplaySuppression() {
        guard !verifiedReplayRenderSuppressed else { return }
        let action = renderPresentationGate.setSuppressed(false)
        if case .started(_) = action,
           startPromotedRenderSubmission(action) {
            return
        }
        // A request can arrive while a replay token is still completing. If
        // it was intentionally retained as dirty work rather than a gate
        // entry, give it one immediate chance after suppression is lifted.
        guard needsDraw else { return }
        needsDraw = false
        if !requestRender() {
            needsDraw = true
        }
    }

    /// Request a geometry recompute on the next display-link frame. Triggers
    /// must call this instead of `syncSurfaceGeometry` directly so rapid
    /// events coalesce into one apply per frame.
    private func setNeedsGeometrySync(reassertNaturalSize: Bool = true) {
        needsGeometrySync = true
        if reassertNaturalSize { pendingGeometryReassert = true }
        needsDraw = true
        // A geometry sync (for any reason) satisfies a pending post-zoom resync.
        zoomSettleFrames = nil
        if displayLink == nil, window != nil {
            // No frame pump while detached/backgrounded; apply directly so the
            // surface still gets sized before the next render path resumes.
            needsGeometrySync = false
            let reassert = pendingGeometryReassert
            pendingGeometryReassert = false
            syncSurfaceGeometry(shouldReassertNaturalSize: reassert)
        }
    }
    private(set) var configBackgroundColor: UIColor?

    /// Recolors the surface, fallback, cursor, and input accessory in place.
    @MainActor
    func refreshThemeColors() {
        let themeBackground = terminalTheme.terminalBackgroundUIColor
        backgroundColor = themeBackground
        snapshotFallbackView.backgroundColor = themeBackground
        snapshotFallbackView.textColor = terminalTheme.terminalForegroundUIColor
        configBackgroundColor = themeBackground
        (bottomDockHostView as? GhosttySurfaceHostView)?.updateTerminalBackground(themeBackground)
        inputProxy.terminalTheme = terminalTheme
        needsDraw = true
    }

    func applyTerminalConfigTheme(_ theme: TerminalTheme, force: Bool) {
        guard surface != nil else { return }
        let configTheme = theme.validatedOrDefault()
        guard force || appliedTerminalConfigTheme != configTheme else { return }
        appliedTerminalConfigTheme = configTheme
        refreshThemeColors()
        runtime?.applyTheme(configTheme, to: self)
    }

    func setFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    private func syncSurfaceVisibility() {
        guard let surface else { return }
        let visible = window != nil &&
            !isHidden &&
            alpha > 0.01 &&
            bounds.width > 0 &&
            bounds.height > 0
        MobileDebugLog.anchormux("surface.occlusion visible=\(visible) window=\(window != nil) hidden=\(isHidden) alpha=\(alpha)")
        ghostty_surface_set_occlusion(surface, visible)
    }

    /// Require a fresh settled viewport report whenever this view mounts.
    /// Reuses the last measured grid as a candidate, while later layout passes
    /// may supersede it before the debounce finishes.
    @discardableResult
    public func requestViewportReportForMount(
        invalidatingPendingReports: Bool = true
    ) -> UInt64 {
        if invalidatingPendingReports {
            // A report callback can outlive the mount that emitted it. Move
            // the report sequence past every callback already in flight so a
            // retired mount cannot be accepted by the new coordinator.
            viewportReportID &+= 1
        }
        if invalidatingPendingReports {
            viewportReportRetries = 0
        }
        if let pending = lastReportedSize,
           pending.columns > 0,
           pending.rows > 0 {
            pendingViewportReport = pending
            viewportReportSettleFrames = 0
        } else {
            setNeedsGeometrySync(reassertNaturalSize: true)
        }
        return viewportReportID
    }

    /// Re-arm the debounced viewport report after a round-trip returned no
    /// effective grid, so a transient RPC drop does not leave the render pinned
    /// to a stale effective grid (the "stuck letterbox" freeze). Bounded and
    /// display-link driven (the existing settle machinery re-fires it); a
    /// confirmed `applyViewSize` resets the counter. No-op once the cap is hit.
    public func retryViewportReport() {
        guard viewportReportRetries < Self.maxViewportReportRetries,
              let pending = lastReportedSize, pending.columns > 0, pending.rows > 0 else {
            // Round-trip permanently failed (or nothing to retry): stop
            // treating the negotiation as unsettled so layout converges on
            // the best-known (stale) grant instead of staying parked until
            // some future confirmation that may never come.
            if awaitingViewportEcho {
                awaitingViewportEcho = false
                setNeedsGeometrySync(reassertNaturalSize: false)
            }
            return
        }
        viewportReportRetries += 1
        MobileDebugLog.anchormux(
            "zoom.viewport.retry \(viewportReportRetries)/\(Self.maxViewportReportRetries) "
            + "grid=\(pending.columns)x\(pending.rows)"
        )
        pendingViewportReport = pending
        viewportReportSettleFrames = 0
    }

    public func applyViewSize(cols: Int, rows: Int) {
        applyViewSize(cols: cols, rows: rows, confirmedViewportEcho: false)
    }

    /// Apply the daemon's authoritative rendering grid and wait until libghostty
    /// accepts the geometry for the current surface generation.
    /// - Parameter cols: The authoritative terminal column count.
    /// - Parameter rows: The authoritative terminal row count.
    /// - Returns: `false` when the surface reset before the geometry applied.
    @discardableResult
    public func applyViewSizeAndWait(cols: Int, rows: Int) async -> Bool {
        let changed = updateEffectiveGrid(cols: cols, rows: rows, confirmedViewportEcho: false)
        if changed || needsGeometrySync {
            return await syncSurfaceGeometryAndWait(shouldReassertNaturalSize: false)
        }
        return true
    }

    /// Apply the daemon's effective-grid ECHO for the natural-grid report
    /// stamped `reportID` (see `GhosttySurfaceViewDelegate`'s `didResize`).
    ///
    /// Echoes resolve asynchronously, so the reply to an older report can land
    /// after a newer report was already emitted (keyboard closed while the
    /// keyboard-up report was in flight). Applying that stale echo would pin
    /// the surface to a grid it already outgrew — and because the natural grid
    /// is unchanged afterwards, nothing re-reports and the letterbox gap above
    /// the terminal becomes permanent. Drop everything but the newest report's
    /// echo; the in-flight newer report's own echo is the one that settles the
    /// grid.
    public func applyConfirmedViewSize(cols: Int, rows: Int, reportID: UInt64) {
        guard reportID == viewportReportID else {
            MobileDebugLog.anchormux(
                "zoom.viewport.staleEcho id=\(reportID) latest=\(viewportReportID) grid=\(cols)x\(rows)"
            )
            return
        }
        applyViewSize(cols: cols, rows: rows, confirmedViewportEcho: true)
    }

    public func markViewportReportConfirmed() {
        viewportReportRetries = 0
    }

    /// Mark the round-trip for `reportID` as resolved. Only the NEWEST
    /// report's confirmation settles the negotiation: an out-of-order reply
    /// for an older report means the grant answering the current capacity is
    /// still in flight.
    public func markViewportReportConfirmed(reportID: UInt64) {
        viewportReportRetries = 0
        guard reportID == viewportReportID else { return }
        if awaitingViewportEcho {
            awaitingViewportEcho = false
            // Re-run layout now that the negotiation settled. `applyViewSize`
            // schedules a sync only when the echoed grid CHANGED, so an
            // unchanged echo needs this explicit resync (and it re-reports
            // nothing: reassert is false and the natural grid is unchanged).
            setNeedsGeometrySync(reassertNaturalSize: false)
        }
    }

    /// Start a fresh viewport negotiation even though the phone's capacity is
    /// unchanged: re-queue the current capacity report so the display link
    /// hands it to the delegate with a NEW report ID. Used when a replay
    /// frame arrives sized for a grid that does not match this phone's
    /// capacity (stale daemon state after a transport drop), so the daemon
    /// relearns the phone's grid immediately instead of waiting for the next
    /// natural-size change.
    public func reassertViewportCapacityReport() {
        guard let pending = lastReportedSize, pending.columns > 0, pending.rows > 0 else { return }
        viewportReportRetries = 0
        // A pending report always mirrors `lastReportedSize` (they are
        // assigned together in the geometry pass), but never clobber one if
        // that invariant ever changes: the queued report is at least as new.
        if pendingViewportReport == nil {
            pendingViewportReport = pending
            viewportReportSettleFrames = 0
        }
        MobileDebugLog.anchormux(
            "zoom.viewport.reassert grid=\(pending.columns)x\(pending.rows)"
        )
        // The report is serviced by the display link, and this method is
        // called from the replay consumer where the link can be idle or torn
        // down; without a wake the queued report would wait for unrelated UI
        // activity while the caller keeps the presentation frozen.
        needsDraw = true
        startDisplayLink()
    }

    private func applyViewSize(cols: Int, rows: Int, confirmedViewportEcho: Bool) {
        guard updateEffectiveGrid(cols: cols, rows: rows, confirmedViewportEcho: confirmedViewportEcho) else { return }
        // Mark dirty instead of recomputing synchronously. This breaks the
        // feedback loop (didResize → updateTerminalViewport RPC → applyViewSize
        // → syncSurfaceGeometry → didResize …) that, under fast zoom, drove a
        // storm of set_size calls + viewport RPCs. Geometry now settles once
        // per frame, and reassert=false avoids re-reporting the unchanged
        // natural grid back through the round trip.
        setNeedsGeometrySync(reassertNaturalSize: false)
    }

    private func updateEffectiveGrid(cols: Int, rows: Int, confirmedViewportEcho: Bool) -> Bool {
        guard cols > 0, rows > 0 else { return false }
        if confirmedViewportEcho {
            markViewportReportConfirmed()
        }
        if effectiveGrid?.cols == cols && effectiveGrid?.rows == rows { return false }
        MobileDebugLog.anchormux("zoom.applyViewSize eff=\(effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "nil")->\(cols)x\(rows)")
        effectiveGrid = (cols, rows)
        return true
    }

    public func useNaturalViewSize() {
        guard clearEffectiveGrid() else { return }
        setNeedsGeometrySync(reassertNaturalSize: false)
    }

    /// Return to the phone's natural viewport capacity and wait until libghostty
    /// accepts the geometry for the current surface generation.
    /// - Returns: `false` when the surface reset before the geometry applied.
    @discardableResult
    public func useNaturalViewSizeAndWait() async -> Bool {
        let changed = clearEffectiveGrid()
        if changed || needsGeometrySync {
            return await syncSurfaceGeometryAndWait(shouldReassertNaturalSize: false)
        }
        return true
    }

    private func clearEffectiveGrid() -> Bool {
        guard effectiveGrid != nil else { return false }
        MobileDebugLog.anchormux("zoom.useNaturalViewSize eff=\(effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "nil")->nil")
        effectiveGrid = nil
        return true
    }

    /// Pure libghostty resize refinement; `nonisolated` so it runs on the
    /// off-main surface queue (it touches only the passed surface pointer).
    nonisolated private static func fitSurfaceToGrid(
        _ surface: ghostty_surface_t,
        cols: Int,
        rows: Int,
        cellPixelSize: CGSize
    ) -> (requestedW: UInt32, requestedH: UInt32, actual: ghostty_surface_size_s) {
        var requestedW = UInt32(max(1, Int((CGFloat(cols) * cellPixelSize.width).rounded(.down))))
        var requestedH = UInt32(max(1, Int((CGFloat(rows) * cellPixelSize.height).rounded(.down))))

        ghostty_surface_set_size(surface, requestedW, requestedH)
        var actual = ghostty_surface_size(surface)

        // Ghostty's grid calculation subtracts padding and floors partial cells,
        // so the reverse mapping has to be confirmed against Ghostty itself.
        // This keeps the iOS mirror on the exact daemon grid instead of
        // occasionally rendering one column short.
        var steps = 0
        // Bounded refinement: a few single-pixel nudges are enough to land on
        // the exact grid. A high cap let a fast-zoom storm run this loop tens
        // of thousands of times across frames and burn the main thread.
        while steps < 8,
              Int(actual.columns) < cols || Int(actual.rows) < rows {
            if Int(actual.columns) < cols {
                requestedW += 1
            }
            if Int(actual.rows) < rows {
                requestedH += 1
            }
            ghostty_surface_set_size(surface, requestedW, requestedH)
            actual = ghostty_surface_size(surface)
            steps += 1
        }

        return (requestedW, requestedH, actual)
    }

    /// Result of an off-main geometry pass, handed back to the main actor.
    private struct GeometryResult: Sendable {
        let cellPixelSize: CGSize
        let naturalSize: TerminalGridSize
        /// Pinned render size in points when letterboxed to an effective
        /// grid; nil means fill the container.
        let pinnedSize: CGSize?
        /// The font size the surface was rendering at when `cellPixelSize`
        /// was measured. Capacity reports must normalize with THIS font, not
        /// the main-actor `liveFontSize` read at apply time: a zoom queued
        /// between the measurement and the apply makes the pair incoherent
        /// and the base-font normalization off by the zoom ratio — the phone
        /// then reports a grid several times too small (or too large) and
        /// the daemon grants a bogus shared PTY size (the
        /// keyboard-transition font-oscillation bug).
        let measuredFontSize: Float32
    }

    private func syncSurfaceGeometryAndWait(shouldReassertNaturalSize: Bool = true) async -> Bool {
        needsGeometrySync = false
        pendingGeometryReassert = false
        return await withCheckedContinuation { continuation in
            let operationID = registerPendingGeometryApply(continuation: continuation)
            syncSurfaceGeometry(shouldReassertNaturalSize: shouldReassertNaturalSize) { [weak self] applied in
                self?.completePendingGeometryApply(id: operationID, returning: applied)
            }
        }
    }

    private func syncSurfaceGeometry(
        shouldReassertNaturalSize: Bool = true,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        guard !renderPipelineRecoveryPaused else {
            logRecoveryPausedDrop(kind: "geometry")
            completion?(false)
            return
        }
        guard let surface else {
            completion?(true)
            return
        }

        // Capture all main-actor inputs as values, then do every libghostty
        // WRITE (set_content_scale / set_size / fit) and its readback on the
        // serial surface queue. These calls push to libghostty's renderer
        // mailbox with a blocking `.forever` push; on the main thread they
        // hang it until the scene-update watchdog (0x8BADF00D) kills the app.
        // The main thread only applies the UIKit result. This is the single
        // off-main surface owner: main never calls a blocking libghostty API.
        let scale = preferredScreenScale
        // The font the surface will measure with. Font pushes and geometry
        // passes share the serial `outputQueue`, and `liveFontSize` is
        // written on the main thread at the moment the font push is
        // enqueued, so capturing it here (at this pass's enqueue) pairs it
        // with exactly the cell size this pass measures.
        let measuredFontSize = liveFontSize
        // Reserve, from the bottom up, the steady-state chrome: the bottom
        // safe area (the always-visible toolbar clears the home indicator),
        // the open composer band, and the persistent toolbar. The KEYBOARD is
        // deliberately not part of the grid container
        // (`TerminalLetterboxGeometry.terminalContainerSize`): the grid keeps
        // its keyboard-down size and the host slides the full-height render
        // so its bottom edge rides the dock, which means a keyboard toggle
        // never runs a `set_size`, never re-reports capacity, and never
        // reflows the shared PTY. While the HIDE button has suppressed the
        // chrome (`chromeHidden`) the grid reclaims the whole height.
        let snapshot = viewportSnapshot()
        let containerW = snapshot.containerSize.width
        let containerH = snapshot.containerSize.height
        let containerPxW = UInt32(max(1, Int((containerW * scale).rounded(.down))))
        let containerPxH = UInt32(max(1, Int((containerH * scale).rounded(.down))))
        let eff = effectiveGrid
        let requiresExactEffectiveGrid = verifiedReplayRenderSuppressed
        let pushContentScale = abs(lastAppliedContentScale - scale) > 0.001
        if pushContentScale { lastAppliedContentScale = scale }
        let generation = surfaceGeneration

        outputQueue.async { [weak self] in
            if pushContentScale {
                ghostty_surface_set_content_scale(surface, scale, scale)
            }
            ghostty_surface_set_size(surface, containerPxW, containerPxH)
            let measured = ghostty_surface_size(surface)

            var cell = CGSize.zero
            if measured.columns > 0, measured.rows > 0, measured.width_px > 0, measured.height_px > 0 {
                cell = CGSize(
                    width: CGFloat(measured.width_px) / CGFloat(measured.columns),
                    height: CGFloat(measured.height_px) / CGFloat(measured.rows)
                )
            }

            var pinnedSize: CGSize?
            if let eff, eff.cols > 0, eff.rows > 0, cell.width > 0, cell.height > 0 {
                let fillsNaturalGrid = eff.cols >= Int(measured.columns) && eff.rows >= Int(measured.rows)
                let withinOneCell = (Int(measured.columns) - eff.cols) <= 1 && (Int(measured.rows) - eff.rows) <= 1
                let exactGridFitsInsideNatural = eff.cols <= Int(measured.columns)
                    && eff.rows <= Int(measured.rows)
                let pinnedW = CGFloat(eff.cols) * cell.width / scale
                let pinnedH = CGFloat(eff.rows) * cell.height / scale
                let shouldFitEffectiveGrid = !fillsNaturalGrid
                    && (!withinOneCell || requiresExactEffectiveGrid && exactGridFitsInsideNatural)
                if shouldFitEffectiveGrid,
                   pinnedW + 0.5 < containerW || pinnedH + 0.5 < containerH {
                    let fitted = Self.fitSurfaceToGrid(surface, cols: eff.cols, rows: eff.rows, cellPixelSize: cell)
                    let aw = fitted.actual.width_px > 0 ? fitted.actual.width_px : fitted.requestedW
                    let ah = fitted.actual.height_px > 0 ? fitted.actual.height_px : fitted.requestedH
                    pinnedSize = CGSize(
                        width: min(CGFloat(aw) / scale, containerW),
                        height: min(CGFloat(ah) / scale, containerH)
                    )
                }
            }

            let natural = TerminalGridSize(
                columns: Int(measured.columns),
                rows: Int(measured.rows),
                pixelWidth: Int(measured.width_px),
                pixelHeight: Int(measured.height_px)
            )
            let result = GeometryResult(
                cellPixelSize: cell,
                naturalSize: natural,
                pinnedSize: pinnedSize,
                measuredFontSize: measuredFontSize
            )
            Task { @MainActor in
                guard let self else {
                    completion?(true)
                    return
                }
                guard self.surfaceGeneration == generation else {
                    completion?(false)
                    return
                }
                self.applyGeometryResult(
                    result,
                    scale: scale,
                    containerW: containerW,
                    containerH: containerH,
                    shouldReassertNaturalSize: shouldReassertNaturalSize
                )
                completion?(true)
            }
        }
    }

    /// Apply an off-main geometry pass on the main actor: only UIKit layer /
    /// cursor / border work plus the resize report. No blocking libghostty
    /// calls happen here.
    private func applyGeometryResult(
        _ result: GeometryResult,
        scale: CGFloat,
        containerW: CGFloat,
        containerH: CGFloat,
        shouldReassertNaturalSize: Bool
    ) {
        if result.cellPixelSize.width > 0, result.cellPixelSize.height > 0 {
            cellPixelSize = result.cellPixelSize
        }
        // Size the render layer to the EXACT pixel size libghostty rendered
        // (grid-aligned: cols×cellW × rows×cellH), not the raw container. The
        // present path discards any surface whose size != layer.bounds×scale,
        // and ghostty floors the grid to whole cells, so a container-sized
        // layer is up to ~one cell larger than the surface and EVERY frame is
        // discarded (blank terminal). Using the measured surface size makes
        // them match so frames present. Pinned (letterboxed) sizes are already
        // derived from the fitted surface px. Left-align + top-anchor either
        // way; any leftover container space is the letterbox margin.
        let naturalRenderSize = CGSize(
            width: max(1, CGFloat(result.naturalSize.pixelWidth) / scale),
            height: max(1, CGFloat(result.naturalSize.pixelHeight) / scale)
        )
        let measuredRenderRect = result.pinnedSize.map { CGRect(origin: .zero, size: $0) }
            ?? CGRect(origin: .zero, size: naturalRenderSize)
        let snapshot = viewportSnapshot()
        layoutBottomDock(using: snapshot)
        let renderRect = snapshot.renderRect(forRenderSize: measuredRenderRect.size)
        lastRenderRect = renderRect
        MobileDebugLog.anchormux(
            "geom container=\(Int(containerW))x\(Int(containerH)) scale=\(scale) "
            + "cellPx=\(Int(result.cellPixelSize.width))x\(Int(result.cellPixelSize.height)) "
            + "natural=\(result.naturalSize.columns)x\(result.naturalSize.rows) "
            + "eff=\(effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "nil") "
            + "pinned=\(result.pinnedSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil") "
            + "renderRect=\(Int(renderRect.width))x\(Int(renderRect.height))@\(Int(renderRect.minY))"
        )
        syncRendererLayerFrame(scale: scale, renderRect: renderRect)
        updateLetterboxBorder(
            renderRect: renderRect,
            isLetterboxed: snapshot.isLetterboxed(renderSize: renderRect.size)
        )
        needsDraw = true
        // Keep drawing for several frames so a frame lands at the final settled
        // layer size after CoreAnimation commits the bounds change. libghostty
        // discards a present whose surface size != the live layer (avoids the
        // garbled mis-scaled frame), so we must re-draw at the stable size until
        // one passes; otherwise the terminal stays blank. Bounded to avoid a
        // perpetual main-queue present flood. The renderer presents a frame
        // behind (see display link).
        pendingRenderFrames = 6
        syncSnapshotFallback()

        let naturalSize = result.naturalSize
        let reportContainerWidth = columnReportContainerWidth(currentWidth: containerW)
        // Report capacity at the user's base font, not whatever font was
        // rendering when the cell was measured (a coalescing pinch step can
        // make them differ for a frame): a report derived from a transient
        // rendered font would ratchet the negotiated minimum down and the
        // phone could never learn when the constraining device grew back.
        let reportGrid = capacityReportGrid(
            for: naturalSize,
            containerPixelWidth: reportContainerWidth * scale,
            containerPixelHeight: containerH * scale,
            cellPixelWidth: result.cellPixelSize.width,
            cellPixelHeight: result.cellPixelSize.height,
            measuredFontSize: result.measuredFontSize
        )
        // The rendered font is always the user's explicit choice. A grant with
        // fewer rows or columns than the phone's capacity letterboxes inside
        // the render rect (with the border); it never rescales text. The old
        // stretch-to-fill auto-fit re-derived the rendered font from the
        // granted grid, and any window where the grant was stale (reconnect
        // replays, keyboard transitions, lost echoes) momentarily zoomed the
        // terminal past the screen edges until the next negotiation
        // round-trip. Converge any residual drift back to the base size; with
        // no auto-fit, `liveFontSize` can differ from `userBaseFontSize` only
        // while an explicit font change is still coalescing.
        if pendingFontSize == nil, abs(liveFontSize - userBaseFontSize) >= 0.25 {
            MobileDebugLog.anchormux(
                "zoom.converge live=\(liveFontSize) base=\(userBaseFontSize)"
            )
            applyAbsoluteFontSize(userBaseFontSize)
        }
        let effectiveMatchesNatural = effectiveGrid.map { grid in
            grid.cols == naturalSize.columns && grid.rows == naturalSize.rows
        } ?? true
        let shouldReportNaturalSize = reportGrid != lastReportedSize ||
            (shouldReassertNaturalSize && !effectiveMatchesNatural)
        guard shouldReportNaturalSize, reportGrid.columns > 0, reportGrid.rows > 0 else { return }
        lastReportedSize = reportGrid
        // Debounce the actual report (a PTY resize on the Mac) until the grid
        // settles; the display link fires it once it stops changing.
        pendingViewportReport = reportGrid
        viewportReportSettleFrames = 0
        scheduleVisibleArtifactCountUpdate()
    }

    private func syncRendererLayerFrame(scale: CGFloat, renderRect: CGRect) {
        // Resize the render layer WITHOUT CoreAnimation's implicit ~0.25s
        // bounds/position animation. While that animation runs, the layer's
        // presentation size differs from the size libghostty just rendered, and
        // the present path discards any frame whose surface size != the live
        // layer (see `applyGeometryResult`). So after a resize/zoom-settle every
        // draw — including the bounded post-settle burst (~0.1s) — lands
        // mid-animation and is dropped, leaving a blank/stale surface until the
        // next input forces a redraw after the animation finally settled (the
        // "blanked out, typing brought it back" symptom). Disabling implicit
        // actions makes the bounds change land in one step, so a single redraw
        // presents at the final size immediately. The host layer and letterbox
        // border already suppress implicit actions; this keeps the render
        // sublayer consistent.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var geometryChanged = layer.contentsScale != scale
        layer.contentsScale = scale
        for sublayer in layer.sublayers ?? [] where isGhosttyRendererLayer(sublayer) {
            if sublayer.frame != renderRect {
                geometryChanged = true
                sublayer.frame = renderRect
            }
            if sublayer.bounds.size != renderRect.size {
                geometryChanged = true
                sublayer.bounds = CGRect(origin: .zero, size: renderRect.size)
            }
            if sublayer.contentsScale != scale {
                geometryChanged = true
            }
            sublayer.contentsScale = scale
        }
        CATransaction.commit()
        if geometryChanged {
            verifiedReplayGeometryRevision &+= 1
            verifiedReplayReadyFence = nil
            verifiedReplayReadyTransactionID = nil
            if pendingVerifiedReplayPresentation != nil {
                restartPendingVerifiedReplayPresentationForCurrentGeometry()
            } else {
                restartInFlightRenderSubmissionForCurrentGeometry()
            }
        }
    }

    /// Reissues an ordinary or local-scroll submission after a layer resize.
    /// `IOSurfaceLayer` intentionally discards a target whose extent no longer
    /// matches the live layer, so waiting for that callback would otherwise
    /// leave the presentation gate blocked until surface recovery.
    @discardableResult
    private func restartInFlightRenderSubmissionForCurrentGeometry(
        countsAsRetry: Bool = false
    ) -> Bool {
        if !countsAsRetry, renderReplacementInFlight {
            // The prior replacement is still queued or running on the serial
            // output queue. Coalesce this geometry revision behind its
            // disposition instead of enqueueing another overlapping render.
            needsAnotherRender = true
            needsDraw = true
            return true
        }
        guard let current = renderSubmission,
              current.kind != .verifiedReplay,
              let surface,
              current.surface == surface,
              current.generation == surfaceGeneration else {
            return false
        }
        guard !countsAsRetry
                || current.presentationRetryCount < Self.maximumRenderPresentationRetries else {
            MobileDebugLog.anchormux(
                "render.submission.retry_drop reason=retry_limit"
            )
            return false
        }
        let renderer = (layer.sublayers ?? []).first(where: isGhosttyRendererLayer)
        guard let renderer,
              renderer.bounds.width > 0,
              renderer.bounds.height > 0,
              renderer.contentsScale > 0 else {
            return false
        }
        let replacement = RenderSubmission(
            token: makeSurfaceOperationID(),
            generation: surfaceGeneration,
            kind: current.kind,
            surface: surface,
            verifiedReplayRead: current.verifiedReplayRead,
            presentationRetryCount: countsAsRetry
                ? current.presentationRetryCount &+ 1
                : current.presentationRetryCount
        )
        let replaced = replaceInFlightRenderSubmission(with: replacement)
        if replaced {
            renderReplacementInFlight = true
        }
        return replaced
    }

    /// Add / update a 1-pixel separator border around the pinned surface
    /// rect when the container is larger (this device is not the smallest
    /// attached to the shared PTY). Smallest-device layouts have
    /// `isLetterboxed == false` and the border layer is hidden. Uses a
    /// CAShapeLayer so the stroke doesn't intercept touches / key events.
    private func updateLetterboxBorder(renderRect: CGRect, isLetterboxed: Bool) {
        guard isLetterboxed else {
            letterboxBorderLayer?.isHidden = true
            return
        }
        let border: CAShapeLayer = {
            if let existing = letterboxBorderLayer { return existing }
            let b = CAShapeLayer()
            b.name = "cmux.letterboxBorder"
            b.fillColor = UIColor.clear.cgColor
            b.lineWidth = 1.0
            b.zPosition = 1000 // above the Ghostty renderer layer
            b.isHidden = false
            b.actions = [
                "bounds": NSNull(),
                "frame": NSNull(),
                "hidden": NSNull(),
                "opacity": NSNull(),
                "path": NSNull(),
                "position": NSNull(),
                "strokeColor": NSNull(),
            ]
            // Decorative only; let pointer / key events pass through.
            b.isGeometryFlipped = false
            layer.addSublayer(b)
            letterboxBorderLayer = b
            return b
        }()
        border.isHidden = false
        border.strokeColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        border.contentsScale = layer.contentsScale
        if border.frame != layer.bounds {
            border.frame = layer.bounds
        }

        let scale = max(border.contentsScale, 1)
        let lineWidth = border.lineWidth
        let alignedRect = CGRect(
            x: floor(renderRect.minX * scale) / scale,
            y: floor(renderRect.minY * scale) / scale,
            width: ceil(renderRect.width * scale) / scale,
            height: ceil(renderRect.height * scale) / scale
        )
        let pathInset = max(lineWidth / 2, 0.5 / scale)
        let outline = alignedRect.insetBy(dx: pathInset, dy: pathInset)
        let path = UIBezierPath(rect: outline).cgPath
        if border.path != path {
            border.path = path
        }
    }

    func isGhosttyRendererLayer(_ layer: CALayer) -> Bool {
        String(describing: type(of: layer)) == "IOSurfaceLayer"
    }

    private func logLayerTree(reason: String) {
        let hostLayer = layer
        let hostSummary = "\(type(of: hostLayer)) bounds=\(hostLayer.bounds.integral.debugDescription) frame=\(hostLayer.frame.integral.debugDescription) contentsScale=\(hostLayer.contentsScale)"
        let childSummaries = (hostLayer.sublayers ?? []).prefix(4).enumerated().map { index, sublayer in
            "\(index):\(type(of: sublayer)) bounds=\(sublayer.bounds.integral.debugDescription) frame=\(sublayer.frame.integral.debugDescription) hidden=\(sublayer.isHidden) contents=\(sublayer.contents != nil) scale=\(sublayer.contentsScale)"
        }.joined(separator: " | ")
        MobileDebugLog.anchormux("surface.layers reason=\(reason) host=\(hostSummary) children=[\(childSummaries)] fallbackHidden=\(snapshotFallbackView.isHidden) fallbackChars=\(snapshotFallbackView.text.count)")
    }

    private func makeSurface(app: ghostty_app_t) -> ghostty_surface_t? {
        var surfaceConfig = ghostty_surface_config_new()
        let retainedBridge = Unmanaged.passRetained(bridge)
        let bridgePointer = retainedBridge.toOpaque()
        surfaceConfig.userdata = bridgePointer
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_IOS
        surfaceConfig.platform = ghostty_platform_u(
            ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(self).toOpaque())
        )
        surfaceConfig.scale_factor = preferredScreenScale
        surfaceConfig.font_size = liveFontSize
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        surfaceConfig.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        surfaceConfig.io_write_cb = GhosttySurfaceBridge.ioWriteCallback
        surfaceConfig.io_write_userdata = bridgePointer
        guard let createdSurface = ghostty_surface_new(app, &surfaceConfig) else {
            retainedBridge.release()
            return nil
        }
        guard ghostty_surface_set_render_presented_callback(
            createdSurface,
            GhosttySurfaceBridge.renderPresentedCallback,
            bridgePointer
        ) else {
            ghostty_surface_free(createdSurface)
            retainedBridge.release()
            return nil
        }
        guard ghostty_surface_set_render_failed_callback(
            createdSurface,
            GhosttySurfaceBridge.renderFailedCallback,
            bridgePointer
        ) else {
            ghostty_surface_free(createdSurface)
            retainedBridge.release()
            return nil
        }
        return createdSurface
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

    func drawForWakeup() {
        guard surface != nil, window != nil, !isDismantled else { return }
        // Don't call `ghostty_surface_refresh` here: that wakes the renderer
        // thread to present asynchronously (`setSurface` → `dispatch_async` to
        // main → size-guard discard), which both blanks frames and competes
        // with the display-link's main-thread present. Just flag dirty; the
        // next display-link tick runs `render_now` on main (which itself does
        // drainMailbox + updateFrame), keeping a single present owner on main.
        needsDraw = true
    }

    func visibleSnapshotTextForTesting() -> String {
        snapshotFallbackView.attributedText?.string ?? snapshotFallbackView.text
    }

    func visibleSnapshotAttributedTextForTesting() -> NSAttributedString? {
        snapshotFallbackView.attributedText
    }

    func isUsingSnapshotFallbackForTesting() -> Bool {
        !snapshotFallbackView.isHidden
    }

    private func syncSnapshotFallback() {
        // Once the Metal renderer is active (surface has received output),
        // keep the fallback hidden so the IOSurfaceLayer is visible.
        if surfaceHasReceivedOutput {
            snapshotFallbackView.isHidden = true
            return
        }

        let snapshot = renderedTextForTesting() ?? ""
        guard !snapshot.isEmpty else {
            lastSnapshotFallbackHTML = nil
            snapshotFallbackView.attributedText = nil
            snapshotFallbackView.text = ""
            snapshotFallbackView.isHidden = true
            return
        }

        let html = renderedHTMLForTesting()
        if let html,
           html != lastSnapshotFallbackHTML,
           let attributedSnapshot = makeSnapshotAttributedText(from: html) {
            lastSnapshotFallbackHTML = html
            snapshotFallbackView.attributedText = attributedSnapshot
            applySnapshotFallbackTheme(from: attributedSnapshot)
        } else if snapshotFallbackView.attributedText?.string != snapshot {
            lastSnapshotFallbackHTML = nil
            snapshotFallbackView.attributedText = nil
            snapshotFallbackView.text = snapshot
        }

        if snapshotFallbackView.text != snapshot && snapshotFallbackView.attributedText == nil {
            snapshotFallbackView.text = snapshot
        }

        let visibleTextLength = snapshotFallbackView.attributedText?.string.utf16.count ?? snapshotFallbackView.text.utf16.count
        if visibleTextLength > 0 {
            snapshotFallbackView.scrollRangeToVisible(NSRange(location: max(0, visibleTextLength - 1), length: 1))
        }
        snapshotFallbackView.isHidden = false
        flushSnapshotFallbackPresentation()
    }

    private func flushSnapshotFallbackPresentation() {
        snapshotFallbackView.textContainer.size = snapshotFallbackView.bounds.size
        snapshotFallbackView.layoutManager.ensureLayout(for: snapshotFallbackView.textContainer)
        snapshotFallbackView.layoutManager.invalidateDisplay(
            forCharacterRange: NSRange(location: 0, length: snapshotFallbackView.textStorage.length)
        )
        snapshotFallbackView.setNeedsDisplay()
    }

    private func makeSnapshotAttributedText(from html: String) -> NSAttributedString? {
        let wrappedHTML = """
        <style>
        body {
            margin: 0;
            padding: 0;
            font-family: Menlo, Monaco, monospace;
            font-size: 13px;
            line-height: 1.25;
        }
        div, pre {
            white-space: pre-wrap;
        }
        </style>
        \(html)
        """
        guard let wrappedData = wrappedHTML.data(using: .utf8) else { return nil }
        return try? NSMutableAttributedString(
            data: wrappedData,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        )
    }

    private func applySnapshotFallbackTheme(from attributedText: NSAttributedString) {
        guard attributedText.length > 0 else {
            snapshotFallbackView.backgroundColor = terminalTheme.terminalBackgroundUIColor
            snapshotFallbackView.textColor = terminalTheme.terminalForegroundUIColor
            return
        }

        let probeIndex = firstVisibleThemeAttributeIndex(in: attributedText)
        if let background = attributedText.attribute(.backgroundColor, at: probeIndex, effectiveRange: nil) as? UIColor {
            snapshotFallbackView.backgroundColor = background
        } else {
            snapshotFallbackView.backgroundColor = terminalTheme.terminalBackgroundUIColor
        }
    }

    private func firstVisibleThemeAttributeIndex(in attributedText: NSAttributedString) -> Int {
        let fullString = attributedText.string
        for (index, scalar) in fullString.unicodeScalars.enumerated() {
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return index
            }
        }
        return 0
    }

    nonisolated private static func handleWrite(
        userdata: UnsafeMutableRawPointer?,
        data: UnsafePointer<CChar>?,
        len: UInt
    ) {
        guard let userdata, let data, len > 0 else { return }
        let bytes = Data(bytes: data, count: Int(len))
        #if DEBUG
        // Detect OSC responses (ESC ] ...) flowing back to the remote terminal.
        // OSC 11 response = "\x1b]11;rgb:RRRR/GGGG/BBBB..." (background color report).
        if bytes.count < 200, let str = String(data: bytes, encoding: .utf8) {
            let escaped = str.unicodeScalars.map { scalar in
                scalar.value < 32 || scalar.value == 127
                    ? String(format: "\\x%02x", scalar.value)
                    : String(scalar)
            }.joined()
            if escaped.contains("\\x1b]") || escaped.contains("\\x1b[") {
                log.debug("io_write OSC/CSI response (\(bytes.count, privacy: .public) bytes): \(escaped, privacy: .public)")
            }
        }
        #endif
        GhosttySurfaceBridge.fromOpaque(userdata)?.handleWrite(bytes)
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


}

extension GhosttySurfaceView: UIGestureRecognizerDelegate {
    /// Keep a tap that lands on the visible zoom HUD from also focusing the
    /// terminal (which would pop the keyboard). Only the focus tap carries this
    /// delegate, so scroll/pinch are unaffected.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        if let zoomOverlay, zoomOverlayShown, zoomOverlay.alpha > 0.01,
           let touched = touch.view, touched.isDescendant(of: zoomOverlay) {
            return false
        }
        // A tap inside the hosted composer band belongs to the compose field /
        // buttons, not the terminal's focus tap (which would steal first responder
        // from the field and fight the keyboard). The band is a surface subview, so
        // the surface-level tap recognizer would otherwise also fire; exclude it.
        if !composerContainer.isHidden,
           let touched = touch.view, touched.isDescendant(of: composerContainer) {
            return false
        }
        if let touched = touch.view, artifactChipHost.contains(touched) {
            return false
        }
        return true
    }
}

extension GhosttySurfaceView: UIScrollViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === scrollMechanicsView,
              !scrollMechanicsIsRecentering else {
            return
        }

        let offsetY = scrollView.contentOffset.y
        guard let previousOffsetY = lastScrollMechanicsOffsetY else {
            lastScrollMechanicsOffsetY = offsetY
            return
        }

        let deltaY = offsetY - previousOffsetY
        lastScrollMechanicsOffsetY = offsetY
        if scrollView.isTracking || scrollView.isDragging {
            lastScrollMechanicsTouchPoint = scrollView.panGestureRecognizer.location(in: self)
        }
        let fallbackPoint = CGPoint(x: bounds.midX, y: bounds.midY)
        let touchPoint = bounds.contains(lastScrollMechanicsTouchPoint)
            ? lastScrollMechanicsTouchPoint
            : fallbackPoint
        enqueueScrollMechanicsDelta(deltaY, touchPoint: touchPoint)
        recenterScrollMechanicsViewIfNeeded()
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === scrollMechanicsView else { return }
        // Reveal on touch-down and hold the chip (no linger) while the finger
        // is down; the end/deceleration callbacks arm the fade-out. Recorded
        // even before any chip content mounts (see noteArtifactChipScrollActivity).
        revealArtifactChipForScroll()
    }

    public func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        guard scrollView === scrollMechanicsView, !decelerate,
              artifactChipScrollRevealed else { return }
        armArtifactChipRevealLinger()
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === scrollMechanicsView,
              artifactChipScrollRevealed else { return }
        armArtifactChipRevealLinger()
    }
}

/// Internal for `GhosttySurfaceView+RenderRecovery.swift` replay decisions.
nonisolated enum RenderPipelineRecoveryReplay {
    case callerWillRequestReplay
    case delegateWhenNoCaller
}

/// One output/geometry operation awaiting either its output-queue completion or
/// the display-link deadline that rebuilds the stalled render pipeline.
/// Internal for `GhosttySurfaceView+RenderRecovery.swift` deadline handling.
nonisolated struct PendingSurfaceOperation {
    let id: UInt64
    let startedAt: CFTimeInterval
    let byteCount: Int?
    let continuation: CheckedContinuation<Bool, Never>
}

/// One visible-terminal snapshot read awaiting output-queue completion or its
/// display-link deadline. A timeout skips only the pending text snapshot.
/// Internal for `GhosttySurfaceView+RenderRecovery.swift` deadline handling.
nonisolated struct PendingVisibleSnapshot {
    let id: UInt64
    let startedAt: CFTimeInterval
    let continuation: CheckedContinuation<(text: String, columns: Int)?, Never>
}

/// One verified-replay viewport-anchor capture awaiting output-queue completion
/// or its skip-only display-link deadline.
nonisolated struct PendingVerifiedReplayViewportAnchorCapture {
    let id: UInt64
    let startedAt: CFTimeInterval
    let continuation: CheckedContinuation<VerifiedReplayCapturedViewportAnchor?, Never>
}

/// One verified-replay viewport-anchor restore awaiting output-queue completion
/// or its skip-only display-link deadline.
nonisolated struct PendingVerifiedReplayViewportAnchorRestore {
    let id: UInt64
    let startedAt: CFTimeInterval
    let continuation: CheckedContinuation<Bool, Never>
}

/// One "View as Text" read awaiting output-queue completion or deadline.
/// Internal for `GhosttySurfaceView+RenderRecovery.swift` deadline handling.
nonisolated struct PendingCopyableTextRead {
    let id: UInt64
    let startedAt: CFTimeInterval
    fileprivate let cancellation: SurfaceOperationCancellationToken
    let continuation: CheckedContinuation<String?, Never>

    func cancel() {
        cancellation.cancel()
    }
}


/// Raw full-text read payload captured by the off-main output queue.
///
/// The C surface pointer is dereferenced only on `GhosttySurfaceWorkQueue`,
/// which is the same FIFO queue that owns `process_output` and surface free.
nonisolated private struct CopyableTextRead: @unchecked Sendable {
    let surface: ghostty_surface_t
    let generation: UInt64
    let cancellation: SurfaceOperationCancellationToken
}

nonisolated private final class SurfaceOperationCancellationToken: Sendable {
    // lint:allow lock - tiny cross-queue cancellation flag for already-enqueued
    // libghostty work; actor hops would put the serial surface queue back behind
    // the main actor and defeat the stale-read fast path.
    private let cancelled: Mutex
        <Bool> = .init(false)

    var isCancelled: Bool {
        cancelled.withLock { $0 }
    }

    func cancel() {
        cancelled.withLock { $0 = true }
    }
}

private class DisplayLinkProxy {
    private weak var target: GhosttySurfaceView?

    init(target: GhosttySurfaceView) {
        self.target = target
    }

    @objc func handleDisplayLink() {
        target?.handleDisplayLinkFire()
    }
}

#endif
