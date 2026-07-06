#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileSupport
import CmuxMobileTerminalKit
import GhosttyKit
import OSLog
import Synchronization
import UIKit

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "ghostty.surface")

public struct GhosttySurfaceInputFocusToken {
    fileprivate weak var view: GhosttySurfaceView?
}

public final class GhosttySurfaceView: UIView, TerminalSurfaceHosting {
    /// The surface whose hidden text input is currently first responder, if any.
    ///
    /// Tracked statically so chrome (SwiftUI overlays presented over the
    /// terminal) can dismiss the live keyboard via ``resignActiveInput()``
    /// without holding a reference to the specific surface.
    private static weak var activeInputSurface: GhosttySurfaceView?
    private weak var runtime: GhosttyRuntime?
    private weak var delegate: GhosttySurfaceViewDelegate?
    private let fontSize: Float32
    /// Surface-owned live font size (points). Zoom mutates this; it is the
    /// source of truth for the current size, so the size accumulates correctly
    /// across taps even though the actual libghostty apply is coalesced.
    private var liveFontSize: Float32
    /// The user's EXPLICIT font choice: the init font until a pinch, accessory
    /// zoom step, overlay reset, or Mac-pushed `set_font` changes it. The
    /// stretch-to-fill auto-fit renders at a derived size but never moves this
    /// baseline, and viewport reports advertise the row capacity at THIS size
    /// (see `TerminalRowCapacityFit`) so the daemon negotiation can always
    /// recover when the constraining device grows.
    private var userBaseFontSize: Float32
    /// Latest zoom target awaiting a coalesced apply. The display link applies
    /// it once per frame via an absolute `set_font_size` so a burst of zoom
    /// taps becomes one libghostty push + resize per frame, instead of one per
    /// tap. That keeps the serial `outputQueue` from accumulating blocking
    /// pushes (mailbox `.forever` push / swap-chain wait) faster than the
    /// per-frame render drains them — the wedge that froze zoom.
    private var pendingFontSize: Float32?
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
    private var bridge = GhosttySurfaceBridge()
    private let prefersSnapshotFallbackRendering = false
    var onFocusInputRequestedForTesting: (() -> Void)?
    private var surfaceTitle: String?
    private var displayLink: CADisplayLink?
    private var cursorBlinkState = TerminalCursorBlinkState()
    private var cursorOverlayLayer: CALayer?
    /// Whether the host terminal currently wants the cursor shown (DECTCEM).
    /// TUIs that hide the cursor (vim, fzf, htop, less, …) emit `ESC [ ? 25 l`;
    /// the render-grid producer forwards that in the VT-patch bytes, so we track
    /// the last applied state from the byte stream and hide the overlay to
    /// match. Defaults to visible (a normal shell shows its cursor).
    private var hostCursorVisible: Bool = true
    private var needsDraw: Bool = false
    /// Countdown of extra draw requests after a geometry change, so the
    /// renderer (which presents a frame behind) produces a frame at the final
    /// settled layer size rather than leaving a stale mid-animation surface.
    /// Bounded to avoid a perpetual main-queue present flood.
    private var pendingRenderFrames: Int = 0
    /// At most one `render_now` is in flight on `outputQueue` at a time. The
    /// display link can fire at 120Hz and previously enqueued a render every
    /// frame with no guard, so during a continuous pinch renders piled up
    /// faster than the serial queue drained them. Each op stayed fast, but the
    /// DISPLAYED frame fell seconds behind the live font and only caught up
    /// when zoom stopped and the backlog drained — the "frozen, no updates"
    /// symptom. Coalescing caps the backlog: while a render is in flight, mark
    /// `needsAnotherRender` and re-enqueue exactly one when it completes.
    private var renderInFlight: Bool = false
    private var renderInFlightSince: CFTimeInterval?
    private var needsAnotherRender: Bool = false
    /// True while inactive/backgrounded. `render_now` can block on GPU frame
    /// acquisition if iOS backgrounds the app mid-frame, so suspend while the
    /// GPU is still available and gate future render dispatches until foreground.
    var renderingSuspended: Bool = false
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
    private var lastAppliedContentScale: CGFloat = 0
    var surfaceHasReceivedOutput: Bool = false
    private var shouldScrollInitialOutputToBottom = true
    /// Serial background queue for `ghostty_surface_process_output`, which
    /// blocks on libghostty's internal renderer/IO futex. Running it on the
    /// main thread hangs the app until the scene-update watchdog kills it.
    /// Internal (not private) so the copyable-text extension in
    /// `GhosttySurfaceCopyableText.swift` can enqueue its surface read with
    /// the same FIFO-before-dispose ordering discipline.
    var outputQueue = GhosttySurfaceWorkQueue(generation: 0)
    private var outputQueueGeneration: UInt64 = 0
    private var pendingSurfaceFreeCount = 0
    var renderPipelineRecoveryPaused = false
    private var lastRecoveryPausedDropLogTime: CFTimeInterval = 0
    private static let renderPipelineStallDeadline: CFTimeInterval = 2.0
    private static let outputApplyTimeout: CFTimeInterval = 2.0
    private static let visibleSnapshotTimeout: CFTimeInterval = 0.6
    private static let copyableTextTimeout: CFTimeInterval = 2.0
    private static let surfaceFreeBacklogWarningThreshold = 1
    private static let surfaceFreeBacklogRecoveryLimit = 2
    private var nextSurfaceOperationID: UInt64 = 0
    private var pendingOutputApply: PendingSurfaceOperation?
    private var pendingGeometryApply: PendingSurfaceOperation?
    private var pendingVisibleSnapshot: PendingVisibleSnapshot?
    var pendingSnapshotFallbackRead: PendingSnapshotFallbackRead?
    private var pendingCopyableTextRead: PendingCopyableTextRead?
    private var hasPendingSurfaceOperationDeadline: Bool {
        pendingOutputApply != nil || pendingGeometryApply != nil || pendingVisibleSnapshot != nil ||
            pendingSnapshotFallbackRead?.timedOut == false
            || pendingCopyableTextRead != nil
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
        return [
            "chromeHidden=\(chromeHidden ? 1 : 0)",
            "composerActive=\(composerActive ? 1 : 0)",
            "fieldFocused=\(composerFieldIsFirstResponder ? 1 : 0)",
            "keyboardUp=\(keyboardVisible ? 1 : 0)",
            "proxyFirstResponder=\(inputProxy.isFirstResponder ? 1 : 0)",
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
    private var snapshotFallbackVisualView: UIView?

    private(set) var surface: ghostty_surface_t?
    var surfaceGeneration: UInt64 = 0
    private var lastReportedSize: TerminalGridSize?
    /// Latest natural grid awaiting a debounced report to the Mac. The display
    /// link sends it only after the grid has held steady for
    /// `viewportReportSettleThreshold` frames. Reporting every intermediate
    /// size during the attach / keyboard / zoom settle resized the Mac PTY
    /// repeatedly, so the shell redrew its prompt on each SIGWINCH and the
    /// initial scrollback filled with the prompt duplicated at every width.
    private var pendingViewportReport: TerminalGridSize?
    private var viewportReportSettleFrames = 0
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
    private var lastRecoverySnapshotText: String = ""
    /// Daemon-authoritative grid used for modes that need exact remote-cell
    /// replay. When nil, the surface fills the phone's natural capacity.
    private var effectiveGrid: (cols: Int, rows: Int)?
    /// Cached cell metrics derived from the most recent
    /// `ghostty_surface_size` measurement. Used to translate an effective
    /// cols×rows pin into a pixel box without re-round-tripping through
    /// Ghostty. Zero until the first layout has measured.
    private var cellPixelSize: CGSize = .zero
    /// 1 px separator stroke drawn around the pinned surface rect when the
    /// container is larger than the render target (i.e., this device is
    /// not the smallest). Added lazily on first letterbox.
    private var letterboxBorderLayer: CAShapeLayer?
    /// Last render rect used for the Ghostty surface inside the host view's
    /// coordinate space. Kept so the border layer can match it without a
    /// second set_size round-trip.
    private var lastRenderRect: CGRect = .zero
    private var lastRenderLayoutViewportHeight: CGFloat?
    private var lastRenderHasSourceLayoutViewport = false
    private var viewportCoordinator = TerminalViewportCoordinator()
    private var keyboardHeightAnimation: TerminalKeyboardHeightAnimation?
    private var keyboardHeightAnimationID = 0

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
        stopKeyboardHeightAnimation()
        keyboardHeight = max(0, height)
        layoutRenderedTerminalForCurrentViewport()
        layoutBottomDock()
        syncSurfaceGeometry(shouldReassertNaturalSize: true)
    }

    @discardableResult
    func simulateRenderRecoveryWithStuckPriorFreeForTesting() -> Bool {
        pendingSurfaceFreeCount = max(pendingSurfaceFreeCount, Self.surfaceFreeBacklogWarningThreshold)
        return recoverRenderPipeline(
            reason: "test_stuck_prior_free",
            stalledMs: Int(Self.renderPipelineStallDeadline * 1000),
            replay: .delegateWhenNoCaller
        )
    }

    @discardableResult
    func simulateRenderRecoveryAtSurfaceFreeLimitForTesting() -> Bool {
        pendingSurfaceFreeCount = max(pendingSurfaceFreeCount, Self.surfaceFreeBacklogRecoveryLimit)
        return recoverRenderPipeline(
            reason: "test_surface_free_limit",
            stalledMs: Int(Self.renderPipelineStallDeadline * 1000),
            replay: .delegateWhenNoCaller
        )
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

    #if DEBUG
    /// Structured diagnostic log (DEBUG dogfood builds only), property-injected
    /// from the shell store by ``GhosttySurfaceRepresentable`` so the
    /// composer-dock probes land in the blob the diagnostic export captures.
    /// `nil` in hosts that do not wire it; every probe is then a no-op. The
    /// property does not exist in release builds — every reader is inside a
    /// `#if DEBUG` block.
    public var diagnosticLog: DiagnosticLog?
    #endif

    private lazy var inputProxy: TerminalInputTextView = {
        let inputProxy = TerminalInputTextView()
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
        inputProxy.onToggleComposer = { [weak self] in
            guard let self else { return }
            self.handleComposerButtonTap()
        }
        inputProxy.onHideKeyboard = { [weak self] in
            guard let self else { return }
            #if DEBUG
            // The keyboard-toggle was tapped while composing. Round 8 no longer
            // dismisses the composer here (the composer survives a keyboard-down), so
            // this is now purely diagnostic.
            if self.composerActive {
                let frOwner = TerminalInputTextView.responderIdentity(of: CurrentResponderProbe().current())
                self.diagnosticLog?.record(DiagnosticEvent(
                    .composerKeyboardToggleWhilePresented,
                    ms: UInt32(max(0, self.keyboardHeight)),
                    a: self.inputProxy.isFirstResponder ? 1 : 0,
                    b: frOwner.rawValue
                ))
            }
            #endif
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
                if self.inputProxy.isFirstResponder {
                    self.resignInput()
                } else {
                    self.composerContainer.endEditing(true)
                }
            } else {
                self.focusInput()
            }
        }
        inputProxy.onHideChrome = { [weak self] in
            self?.setChromeHidden(true)
        }
        inputProxy.onOpenToolbarSettings = { [weak self] in
            guard let self else { return }
            self.delegate?.ghosttySurfaceViewDidRequestToolbarSettings(self)
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

    public init(runtime: GhosttyRuntime, delegate: GhosttySurfaceViewDelegate, fontSize: Float32 = 10) {
        self.runtime = runtime
        self.delegate = delegate
        self.fontSize = fontSize
        self.liveFontSize = fontSize
        self.userBaseFontSize = fontSize
        super.init(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        bridge.attach(to: self)
        // The local view background (the area behind/around the rendered cells,
        // and the letterbox fill) is sourced from the synced theme rather than a
        // hardcoded color, so a fresh mount already shows the Mac's background and
        // a later theme change can recolor it live. `applyBackgroundColorFromConfig`
        // refines this from the runtime config once a surface exists, but the
        // config can be stale on the process singleton across a theme change, so
        // the theme store is the authoritative source for this view's background.
        backgroundColor = GhosttyRuntime.currentBackgroundUIColor
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
        installPersistentToolbar()
        installComposerContainer()
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    @objc private func handleAppWillResignActive() {
        suspendRendering()
    }

    @objc private func handleAppDidEnterBackground() {
        // Backstop: `willResignActive` already suspended, but guarantee the
        // surface is occluded before the GPU goes away.
        suspendRendering()
    }

    @objc private func handleAppDidBecomeActive() {
        resumeRendering()
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
        needsAnotherRender = false
        guard let surface, window != nil else { return }
        ghostty_surface_set_occlusion(surface, true)  // true = visible
        setFocus(true)
        needsDraw = true
        startDisplayLink()
    }

    private var keyboardHeight: CGFloat = 0
    private var keyboardVisible = false
    /// Height the persistent bottom toolbar reserves in the terminal grid. The
    /// toolbar is docked above the keyboard (when up) or the home indicator
    /// (when down) via `keyboardLayoutGuide`, so the grid must shrink by this
    /// much to keep the bottom TUI rows visible above it. 0 until the toolbar is
    /// installed (`installPersistentToolbar`), so the home-indicator reservation
    /// still lands even if the toolbar UI is absent.
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
    /// The docked accessory bar. Positioned by ``bottomDockFrames()`` with the
    /// SAME bottom-occupancy math as the grid reservation, so its top is always
    /// flush with the grid bottom (no gap) and its bottom rests on the keyboard
    /// edge (up) or above the home indicator (down).
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
    /// cannot import the UI package). The surface positions it itself — pinned
    /// directly above the keyboard (iMessage's field-nearest-keyboard layout), with
    /// the docked toolbar riding its top edge and the terminal grid above that — and
    /// reserves its height in the grid, so the compose field, the toolbar, and the
    /// keyboard all live in the surface's single coordinate system (see
    /// ``bottomDockFrames()`` for the `terminal / toolbar / composer / keyboard`
    /// stack). Replaces the round-5/6 `safeAreaInset`-plus-toolbar-handoff that
    /// fought the surface's frame math.
    private let composerContainer = UIView()
    /// Height (points) the open composer band reserves above the keyboard edge. Fed
    /// by the host from the hosted compose field's intrinsic content size
    /// (``setComposerBandHeight(_:animated:)``); 0 while the composer is closed. The
    /// grid reservation adds this so a field-grow pushes the toolbar and terminal
    /// above it upward while the band stays pinned to the keyboard — the keyboard
    /// itself never moves.
    private var composerBandHeight: CGFloat = 0
    /// True once SwiftUI has dismantled the hosting representable for this
    /// surface. A dismantled surface performs no render, output, or
    /// accessibility work so a view SwiftUI has removed cannot keep driving the
    /// renderer or the accessibility tree.
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

    @objc private func handleKeyboardWillChangeFrame(_ notification: Notification) {
        guard let transition = MobileKeyboardTransition(notification: notification) else { return }
        let overlap = transition.overlap(in: self)
        let willBeVisible = transition.isVisible(in: self)
        guard abs(overlap - keyboardHeight) > 0.5 || willBeVisible != keyboardVisible else { return }
        let wasVisible = keyboardVisible
        #if DEBUG
        // The composer-up/keyboard-down desync can be reached WITHOUT the dismiss
        // button (code 24): a swipe-to-dismiss, an attached hardware keyboard, or
        // backgrounding all collapse the keyboard straight through this visible→false
        // transition. Codes 23/24 are silent on those paths, so the onset of the
        // desync — `keyboardVisible→false while the composer is still active` — is recorded
        // here too, with the resolved first-responder owner, so a Capture&Send trace
        // is complete no matter how the keyboard went down. Pure diagnostics; the hide
        // behavior below is unchanged.
        if wasVisible, !willBeVisible, composerActive {
            let frOwner = TerminalInputTextView.responderIdentity(of: CurrentResponderProbe().current())
            MobileDebugLog.anchormux(
                "composer.keyboardHideWhilePresented prevKeyboardHeight=\(Int(keyboardHeight)) frOwner=\(frOwner.rawValue) proxyIsFR=\(inputProxy.isFirstResponder ? 1 : 0)"
            )
        }
        #endif
        keyboardVisible = willBeVisible
        inputProxy.setKeyboardShown(willBeVisible)
        // Round 8 removes the `composerPresented ⇒ keyboardUp` enforcement: the
        // toolbar is ALWAYS visible and the composer band survives a keyboard-down, so
        // the keyboard collapsing no longer dismisses the composer. The composer's
        // draft lives in the store (`terminalInputText`), so the field just loses focus
        // and its text stays; tapping it refocuses and re-raises the keyboard. The
        // composer is dismissed only by its chevron or the toolbar composer button.
        //
        // The toolbar stays visible while the keyboard is down (it now rides the bottom
        // safe area), so visibility does not change here. Re-seat the dock and re-sync
        // the grid: `keyboardOccupancyInBounds` flips from the keyboard height to the
        // safe-area inset, so the dock drops to ride the home indicator and the grid
        // reclaims the keyboard's space (minus the now-reserved safe area + toolbar +
        // composer band).
        updateDockedToolbarVisibility()
        startKeyboardHeightAnimation(to: overlap, transition: transition)
    }

    private func startKeyboardHeightAnimation(
        to targetHeight: CGFloat,
        transition: MobileKeyboardTransition
    ) {
        stopKeyboardHeightAnimation()
        let clampedTarget = max(0, targetHeight)
        guard transition.duration > 0, abs(clampedTarget - keyboardHeight) > 0.5 else {
            applyKeyboardHeight(clampedTarget)
            if clampedTarget == 0 {
                scheduleKeyboardHideHeightResync()
            }
            return
        }

        keyboardHeightAnimationID &+= 1
        let animationID = keyboardHeightAnimationID
        keyboardHeightAnimation = TerminalKeyboardHeightAnimation(id: animationID)
        startDisplayLink()
        transition.animate {
            self.applyKeyboardHeight(clampedTarget)
            self.layoutIfNeeded()
        } completion: { _ in
            guard self.keyboardHeightAnimationID == animationID else { return }
            self.finishKeyboardHeightAnimation(targetHeight: clampedTarget)
        }
    }

    private func stopKeyboardHeightAnimation() {
        keyboardHeightAnimationID &+= 1
        keyboardHeightAnimation = nil
    }

    private func finishKeyboardHeightAnimation(targetHeight: CGFloat) {
        stopKeyboardHeightAnimation()
        applyKeyboardHeight(targetHeight)
        if targetHeight == 0 {
            scheduleKeyboardHideHeightResync()
        }
    }

    private func advanceKeyboardHeightAnimation() {
        guard keyboardHeightAnimation != nil else { return }
        layoutRenderedTerminalForCurrentViewport()
        layoutZoomOverlay()
    }

    private func applyKeyboardHeight(_ height: CGFloat) {
        let clamped = max(0, height)
        if abs(keyboardHeight - clamped) > 0.25 {
            keyboardHeight = clamped
            setNeedsGeometrySync()
        }
        layoutBottomDock()
        layoutRenderedTerminalForCurrentViewport()
        layoutZoomOverlay()
    }

    /// Force a follow-up geometry sync shortly after the keyboard-hide layout
    /// pass, so the terminal reliably returns to full height even if the first
    /// sync read a stale safe-area inset or its display-link frame was dropped.
    ///
    /// Runs on the main queue (one runloop later, after UIKit has applied the
    /// keyboard-hide layout) and only while the keyboard is still down and the
    /// view is on a window, so a fast hide/show flicker does not re-shrink the
    /// grid. `setNeedsGeometrySync` itself applies directly when the display link
    /// is stopped, so this guarantees an APPLIED sync, not just a queued one.
    private func scheduleKeyboardHideHeightResync() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.keyboardHeight == 0 else { return }
            self.setNeedsGeometrySync()
        }
    }

    #if DEBUG
    /// Test seam: force a synthetic keyboard height so the keyboard-up layout
    /// (docked toolbar riding the keyboard edge, grid reserving toolbar +
    /// keyboard) can be screenshotted on the simulator, which refuses to render
    /// the software keyboard. Drives the exact same geometry path as a real
    /// keyboard. Used only by the terminal-layout preview harness.
    public func debugSetKeyboardHeightForLayoutPreview(_ height: CGFloat) {
        stopKeyboardHeightAnimation()
        keyboardVisible = height > 0
        inputProxy.setKeyboardShown(keyboardVisible)
        keyboardHeight = max(0, height)
        // Mirror the live keyboard-tied visibility so the preview shows the bar
        // only when the synthetic keyboard is "up".
        updateDockedToolbarVisibility()
        layoutRenderedTerminalForCurrentViewport()
        layoutBottomDock()
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

    /// Dock the accessory bar as a persistent bottom toolbar. Frame-positioned
    /// (not `keyboardLayoutGuide`-pinned) so it uses the exact same bottom
    /// occupancy as the grid reservation and the two never disagree. The grid
    /// reserves its height (see `reservedToolbarHeight`) so the bottom TUI rows
    /// stay visible above it.
    private func installPersistentToolbar() {
        let toolbar = inputProxy.toolbarView
        addSubview(toolbar)
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
        updateDockedToolbarVisibility()
        layoutBottomDock()
    }

    /// Layer `zPosition` for the bottom chrome (toolbar + composer band), placing it
    /// above the Ghostty renderer's sublayer so a lifted Liquid-Glass button is not
    /// clipped by the terminal render bounds (item 6). Below the zoom HUD (1100).
    private static let bottomChromeZPosition: CGFloat = 1000

    /// Whether the always-visible bottom chrome (the docked accessory toolbar and,
    /// when open, the composer band) is currently on screen.
    ///
    /// Round 8 makes the toolbar ALWAYS visible — terminal mode, composer mode,
    /// keyboard up AND down — so the only thing that hides it is the explicit HIDE
    /// button (``chromeHidden``). The toolbar is no longer keyboard-tied. When the
    /// keyboard is down the toolbar (and any open composer) ride above the bottom
    /// safe area instead of disappearing; see ``bottomChromeInset``.
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
    /// Used by ``bottomDockFrames()`` and the grid reservation.
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
        let snapshot = viewportSnapshot()
        return snapshot.renderViewportRect(
            forRenderSize: lastRenderRect.size,
            clampsStaleLiveViewport: shouldClampStaleLiveViewport(using: snapshot)
        ).height
    }

    private var terminalViewportRect: CGRect {
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
            chromeHidden: chromeHidden,
            chromeVisible: dockedToolbarShouldBeVisible && dockedToolbar?.isHidden == false,
            toolbarFrame: dockedToolbar?.frame,
            toolbarPresentationFrame: dockedToolbar?.layer.presentation()?.frame
        ))
    }

    private func shouldClampStaleLiveViewport(using snapshot: TerminalViewportSnapshot) -> Bool {
        guard lastRenderHasSourceLayoutViewport,
              let height = lastRenderLayoutViewportHeight else { return false }
        return abs(height - snapshot.layoutViewportRect.height) <= 1
    }

    private func layoutRenderedTerminalForCurrentViewport() {
        layoutRenderedTerminalForCurrentViewport(using: viewportSnapshot())
    }

    private func layoutRenderedTerminalForCurrentViewport(using snapshot: TerminalViewportSnapshot) {
        snapshotFallbackView.frame = snapshot.layoutViewportRect
        snapshotFallbackVisualView?.frame = snapshot.layoutViewportRect
        guard !lastRenderRect.isEmpty else { return }
        let renderRect = snapshot.renderRect(
            forRenderSize: lastRenderRect.size,
            clampsStaleLiveViewport: shouldClampStaleLiveViewport(using: snapshot)
        )
        guard renderRect != lastRenderRect else { return }
        lastRenderRect = renderRect
        #if DEBUG
        recordBottomViewportMismatchIfNeeded()
        #endif
        syncRendererLayerFrame(scale: preferredScreenScale, renderRect: renderRect)
        updateLetterboxBorder(
            renderRect: renderRect,
            isLetterboxed: snapshot.isLetterboxed(renderSize: renderRect.size)
        )
        updateCursorOverlay()
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
        // Its frame already collapses to `.zero` while hidden (see
        // ``bottomDockFrames()``); toggling `isHidden` also stops it intercepting taps.
        composerContainer.isHidden = !shouldShow || composerContainer.subviews.isEmpty
        reservedToolbarHeight = reserved
        layoutRenderedTerminalForCurrentViewport()
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
    /// (``handleTap``). Animated on the keyboard curve via ``animateBottomDock``.
    private func setChromeHidden(_ hidden: Bool) {
        guard chromeHidden != hidden else { return }
        chromeHidden = hidden
        if hidden, keyboardVisible {
            // Drop the keyboard first; its hide notification re-seats the dock, then
            // the visibility update below removes the toolbar/composer. Resign
            // whichever responder actually owns the keyboard — the band can be
            // presented while the terminal's hidden input proxy (a sibling of
            // `composerContainer`) holds first responder, so gating on
            // `composerActive` alone would leave the keyboard up while the chrome
            // hides.
            if inputProxy.isFirstResponder {
                resignInput()
            } else {
                composerContainer.endEditing(true)
            }
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
            if keyboardVisible, window != nil, !isDismantled, !inputProxy.isFirstResponder {
                Self.activeInputSurface = self
                inputProxy.updateAccessoryLayoutInsets()
                inputProxy.becomeFirstResponder()
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
        let barFrame = dockedToolbar?.frame ?? .zero
        MobileDebugLog.anchormux(
            "composer.toggle active=\(active) keyboardHeight=\(Int(keyboardHeight)) occInBounds=\(Int(keyboardOccupancyInBounds)) barHidden=\(dockedToolbar?.isHidden ?? true) barY=\(Int(barFrame.minY)) barH=\(Int(barFrame.height)) boundsH=\(Int(bounds.height))"
        )
        // COMPOSER: structured event for the item-4 edge case (composer shown while
        // textbox/keyboard hidden). Captures the composer-active transition plus the
        // resolved first-responder owner and keyboardHeight at that instant, into the
        // same sink the round-4 composer flag/appear/focus events use. With these,
        // a captured trace shows whether the composer ever ends up active with the
        // FR owned by no terminal/composer responder and keyboardHeight 0.
        let frOwner = TerminalInputTextView.responderIdentity(of: CurrentResponderProbe().current())
        diagnosticLog?.record(DiagnosticEvent(
            .composerActiveTransition,
            ms: UInt32(max(0, keyboardHeight)),
            a: active ? 1 : 0,
            b: frOwner.rawValue,
            c: inputProxy.isFirstResponder ? 1 : 0
        ))
        #endif
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
        case .openComposer, .closeComposer:
            // Optimistically flip the local mirror to the intent's outcome BEFORE
            // the store round-trip. `composerActive` is otherwise synced back via
            // SwiftUI's `updateUIView`, which runs a render pass after the store
            // mutation — a second tap landing inside that window would read the
            // stale flag, resolve `.openComposer` again, and the toggle would
            // dismiss the composer the first tap just presented. The authoritative
            // sync still arrives via `setComposerActive` (idempotent when the
            // optimistic value already matches).
            setComposerActive(intent == .openComposer)
            delegate?.ghosttySurfaceViewDidRequestComposerToggle(self)
        case .revealAndFocusComposer:
            if chromeHidden {
                setChromeHidden(false)
            }
            delegate?.ghosttySurfaceViewDidRequestComposerFocus(self)
            focusMountedComposerField()
        }
    }

    /// Deterministic UIKit focus for an already-mounted composer band.
    ///
    /// The store handshake (`composerFocusRequest`) drives the SwiftUI field's
    /// `@FocusState`, but a programmatic `@FocusState` set inside a hosting
    /// controller whose view is frame-mounted into the band can be dropped
    /// (observed as a device-dependent flake: the request is consumed yet the
    /// field never becomes first responder). After asking the host to focus,
    /// drive the band's backing text input to first responder directly on the
    /// next runloop hop; SwiftUI mirrors UIKit first responder back into
    /// `@FocusState`, so the store's focus mirror stays consistent. A no-op
    /// when the band is unmounted (the fresh-mount path focuses via the
    /// consumed request in `onAppear`) or the field already holds focus.
    private func focusMountedComposerField() {
        Task { @MainActor [weak self] in
            guard let self,
                  self.composerActive,
                  !self.composerFieldIsFirstResponder,
                  let input = self.composerContainer.firstFocusableTextInputInSubtree() else { return }
            input.becomeFirstResponder()
        }
    }

    /// Install the composer band container into the surface's view hierarchy, above
    /// the docked toolbar. Hidden and zero-height until the host mounts a compose
    /// field into it (``mountComposerView(_:)``); the surface positions it in
    /// ``layoutBottomDock()`` and reserves its height in the grid. Frame-positioned
    /// (`translatesAutoresizingMaskIntoConstraints = true`) like the docked toolbar so
    /// the whole bottom dock shares one coordinate system.
    private func installComposerContainer() {
        composerContainer.backgroundColor = .clear
        composerContainer.isHidden = true
        // Do NOT clip: the composer's Liquid-Glass controls lift/shadow past the band
        // edge, and the band must sit above the Ghostty render layer (item 6) so the
        // glass is not clipped by the terminal bounds. Raised to the same chrome
        // z-position as the toolbar.
        composerContainer.clipsToBounds = false
        composerContainer.layer.zPosition = Self.bottomChromeZPosition
        addSubview(composerContainer)
        layoutBottomDock()
    }

    /// Mount (or unmount, with `nil`) the host-built compose field into the surface's
    /// composer band. The terminal package cannot import the SwiftUI composer (that
    /// would invert the package DAG), so `GhosttySurfaceRepresentable` builds it in a
    /// `UIHostingController` and hands the controller's view here. The surface owns the
    /// band's position and the grid reservation; the host owns the field's content and
    /// reports its measured height via ``setComposerBandHeight(_:animated:)``.
    ///
    /// The mounted view is pinned edge-to-edge inside the band with Auto Layout, so it
    /// fills whatever height the surface frames the band to — there is no second layout
    /// system fighting the surface for the band's frame (the band's own frame is set by
    /// `layoutBottomDock()`).
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
    }

    /// Set the height (points) the open composer band reserves below the docked
    /// toolbar, from the hosted compose field's intrinsic content size. Drives the
    /// grid reservation (so a field-grow pushes only the terminal up) and the dock
    /// layout. When `animated`, the reservation + reflow run inside a `UIView.animate`
    /// using the keyboard curve so the height change reads as one smooth motion with
    /// the rest of the dock (item 3/4). Idempotent: a no-op when the height is
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
            self.layoutIfNeeded()
        }
        if animated {
            UIView.animate(
                withDuration: Self.composerReflowDuration,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState],
                animations: apply,
                completion: { _ in completion?() }
            )
        } else {
            apply()
            completion?()
        }
        setNeedsGeometrySync()
    }

    /// Duration (seconds) of the composer band grow/shrink reflow. Matches the system
    /// keyboard's default animation duration so a field-grow reads as one smooth
    /// motion with the dock; keyboard show/hide reflow samples the notification's
    /// own curve/duration through ``startKeyboardHeightAnimation(to:transition:)``.
    private static let composerReflowDuration: TimeInterval = 0.25

    private func bottomDockFrames() -> (composer: CGRect, toolbar: CGRect) {
        let snapshot = viewportSnapshot()
        return (snapshot.composerFrame, snapshot.toolbarFrame)
    }

    /// Position the composer band and docked toolbar from one viewport snapshot.
    private func layoutBottomDock() {
        layoutBottomDock(using: viewportSnapshot())
    }

    private func layoutBottomDock(using snapshot: TerminalViewportSnapshot) {
        composerContainer.frame = snapshot.composerFrame
        dockedToolbar?.frame = snapshot.toolbarFrame
    }

    /// Animate the whole bottom dock (composer band + toolbar) to its current target
    /// frames over the given duration/curve. Used by the HIDE/show and composer close
    /// paths (item 3), which have no keyboard notification and so default to the system
    /// keyboard duration + easeInOut so the motion still reads as one smooth coordinated
    /// reflow. Real keyboard changes use the per-frame keyboard height owner, so the
    /// exact UIKit keyboard transaction drives the dock.
    private func animateBottomDock(
        duration: TimeInterval = 0.25,
        curveOption: UIView.AnimationOptions = .curveEaseInOut
    ) {
        let frames = bottomDockFrames()
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [curveOption, .beginFromCurrentState]
        ) { [weak self] in
            self?.composerContainer.frame = frames.composer
            self?.dockedToolbar?.frame = frames.toolbar
        }
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

    private func enqueueScrollMechanicsDelta(_ deltaY: CGFloat, touchPoint: CGPoint) {
        // The transparent UIScrollView supplies native iOS tracking,
        // deceleration, and momentum. The Mac still owns terminal semantics:
        // normal-screen scrollback and alt-screen mouse-wheel delivery.
        guard deltaY != 0 else { return }
        let cellHeightPt = cellPixelSize.height / max(preferredScreenScale, 1)
        let divisor = cellHeightPt > 1 ? Double(cellHeightPt) * 3 : 42
        pendingScrollLines += -Double(deltaY) / divisor
        pendingScrollCell = scrollCell(at: touchPoint)
    }

    /// Coalesced native scroll forwarded to the Mac once per display-link frame.
    private var pendingScrollLines: Double = 0
    private var pendingScrollCell: (col: Int, row: Int) = (0, 0)

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

    private func flushPendingScrollIfNeeded() {
        guard pendingScrollLines != 0 else { return }
        let lines = pendingScrollLines
        let cell = pendingScrollCell
        pendingScrollLines = 0
        applyLocalScrollbackScroll(lines: lines, col: cell.col, row: cell.row)
        delegate?.ghosttySurfaceView(self, didScrollLines: lines, atCol: cell.col, row: cell.row)
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
        delegate?.ghosttySurfaceView(self, didTapAtCol: cell.col, row: cell.row)
        // A tap inside the composer band is excluded by the gesture recognizer
        // (`gestureRecognizer(_:shouldReceive:)`), so any tap reaching here is a
        // deliberate terminal tap. Only a reveal-from-hide with the composer still
        // presented re-focuses the composer; every other terminal tap focuses the
        // terminal proxy as before.
        if wasHidden, composerActive {
            delegate?.ghosttySurfaceViewDidRequestComposerFocus(self)
            focusMountedComposerField()
        } else {
            focusInput()
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
        // A pinch/accessory step is an explicit choice: it rebases the user
        // font so the stretch-to-fill auto-fit re-derives from the new size
        // instead of fighting the gesture.
        userBaseFontSize = target
        MobileDebugLog.anchormux("zoom.queue dir=\(direction) \(base)->\(target) live=\(liveFontSize)")
        scheduleDisplayLinkWork()
        showZoomOverlay()
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
    /// the user baseline — the stretch-to-fill auto-fit funnels through here.
    private func applyAbsoluteFontSize(_ target: Float32) {
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
            completion: { [weak overlay] _ in
                if overlay?.alpha == 0 { overlay?.isHidden = true }
            }
        )
    }

    private func ensureZoomOverlay() -> MobileTerminalZoomControlOverlay {
        if let zoomOverlay { return zoomOverlay }
        let overlay = MobileTerminalZoomControlOverlay()
        overlay.alpha = 0
        overlay.isHidden = true
        overlay.layer.zPosition = 1100
        overlay.onInteraction = { [weak self] in
            self?.zoomOverlayLastInteraction = CACurrentMediaTime()
        }
        overlay.onResetToDefault = { [weak self] in
            guard let self else { return }
            let target = self.zoomPreference.savedFontSize
                ?? MobileTerminalFontPreference.defaultSize
            self.applyUserFontSize(target)
            self.zoomOverlay?.updateZoom(points: target)
        }
        overlay.onSaveAsDefault = { [weak self] in
            guard let self else { return }
            self.zoomPreference.save(self.pendingFontSize ?? self.liveFontSize)
        }
        overlay.onRestoreBuiltIn = { [weak self] in
            guard let self else { return }
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
        let bottomReserve = composerBandHeight + reservedToolbarHeight + keyboardOccupancyInBounds
        let availableH = max(1, bounds.height - bottomReserve)
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

    private func recordBottomViewportMismatchIfNeeded() {
        guard debugScrollbarAtBottomForTesting else { return }
        let targetHeight = targetTerminalViewportHeight
        let liveHeight = terminalViewportHeight
        guard liveHeight > targetHeight + 1, lastRenderRect.height <= targetHeight + 1,
              lastRenderRect.minY > 1 else { return }
        debugBottomViewportMismatchObserved = true
    }
    #endif

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        stopKeyboardHeightAnimation()
        disposeSurface()
    }

    public override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let snapshot = viewportSnapshot()
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
        layoutBottomDock(using: snapshot)
        layoutZoomOverlay()
        MobileDebugLog.anchormux("surface.layout bounds=\(Int(bounds.width))x\(Int(bounds.height)) window=\(window != nil)")
        setNeedsGeometrySync()
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
        let snapshot = viewportSnapshot()
        layoutRenderedTerminalForCurrentViewport(using: snapshot)
        layoutBottomDock(using: snapshot)
        setNeedsGeometrySync()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        MobileDebugLog.anchormux("surface.didMoveToWindow window=\(window != nil)")
        syncSurfaceVisibility()
        if window != nil {
            isDismantled = false
            #if DEBUG
            debugAccessibilityProxy.isAccessibilityElement = true
            #endif
            setNeedsGeometrySync()
            setFocus(true)
            if autoFocusOnWindowAttach {
                focusInput()
            }
            startDisplayLink()
        } else {
            prepareForReuseAfterDetach()
        }
    }

    private var lastProcessOutputLogTime: CFTimeInterval = 0

    public func processOutput(_ data: Data) {
        processOutput(data, completion: nil)
    }

    /// Process terminal output and return after the output has been applied.
    ///
    /// The call still performs libghostty output processing on the serial
    /// background output queue. The returned async boundary lets callers apply
    /// per-surface backpressure without blocking the main actor while Ghostty
    /// consumes the chunk.
    /// - Parameter data: VT or PTY bytes to feed into the surface.
    /// - Returns: `true` when the bytes reached the current surface generation,
    ///   or `false` when the caller should reset its delivery queue and replay.
    @discardableResult
    public func processOutputAndWait(_ data: Data) async -> Bool {
        return await withCheckedContinuation { continuation in
            let operationID = registerPendingOutputApply(
                byteCount: data.count,
                continuation: continuation
            )
            processOutput(data) { [weak self] applied in
                self?.completePendingOutputApply(id: operationID, returning: applied)
            }
        }
    }

    func makeSurfaceOperationID() -> UInt64 {
        nextSurfaceOperationID &+= 1
        return nextSurfaceOperationID
    }

    func ensureSurfaceOperationDeadlinePump() {
        guard window != nil, displayLink == nil, !renderingSuspended, !renderPipelineRecoveryPaused else { return }
        startDisplayLink()
    }

    private func registerPendingOutputApply(
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
    private func completePendingOutputApply(id: UInt64, returning result: Bool) -> Bool {
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
    private func checkSurfaceOperationDeadlines(now: CFTimeInterval) -> Bool {
        if let pending = pendingOutputApply,
           now - pending.startedAt >= Self.outputApplyTimeout {
            pendingOutputApply = nil
            let elapsedMs = Int((now - pending.startedAt) * 1000)
            MobileDebugLog.anchormux(
                "output.apply.TIMEOUT bytes=\(pending.byteCount ?? 0) elapsedMs=\(elapsedMs)"
            )
            let recovered = recoverRenderPipeline(
                reason: "output_timeout",
                stalledMs: elapsedMs,
                replay: .callerWillRequestReplay
            )
            pending.continuation.resume(returning: false)
            return recovered
        }

        if let pending = pendingGeometryApply,
           now - pending.startedAt >= Self.outputApplyTimeout {
            pendingGeometryApply = nil
            let elapsedMs = Int((now - pending.startedAt) * 1000)
            MobileDebugLog.anchormux("geometry.apply.TIMEOUT elapsedMs=\(elapsedMs)")
            let recovered = recoverRenderPipeline(
                reason: "geometry_timeout",
                stalledMs: elapsedMs,
                replay: .callerWillRequestReplay
            )
            pending.continuation.resume(returning: false)
            return recovered
        }

        if let pending = pendingVisibleSnapshot,
           now - pending.startedAt >= Self.visibleSnapshotTimeout {
            pendingVisibleSnapshot = nil
            pending.continuation.resume(returning: nil)
        }
        if let pending = pendingSnapshotFallbackRead, !pending.timedOut, now - pending.startedAt >= Self.visibleSnapshotTimeout {
            pendingSnapshotFallbackRead?.timedOut = true
        }

        if let pending = pendingCopyableTextRead,
           now - pending.startedAt >= Self.copyableTextTimeout {
            pendingCopyableTextRead = nil
            pending.cancel()
            pending.continuation.resume(returning: nil)
        }
        return false
    }

    @discardableResult
    private func completePendingSurfaceOperations(returning result: Bool) -> Bool {
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
        skipPendingVisibleSnapshot()
        pendingSnapshotFallbackRead = nil
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
    private func completePendingVisibleSnapshot(id: UInt64, returning section: String?) -> Bool {
        guard let pending = pendingVisibleSnapshot, pending.id == id else { return false }
        pendingVisibleSnapshot = nil
        pending.continuation.resume(returning: section)
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

    private func processOutput(
        _ data: Data,
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
        let generation = surfaceGeneration
        // Track the host's cursor-visible mode (DECTCEM) straight from the VT
        // bytes the surface is about to apply, so the cursor overlay can match a
        // TUI that hides the cursor. nil = this delta carried no DECTCEM, so the
        // previous visibility stands.
        let cursorVisibilityDelta = Self.lastCursorVisibility(in: forwarded)

        // `ghostty_surface_process_output` BLOCKS on libghostty's internal
        // renderer/IO synchronization (a futex). Device crash logs show it
        // hanging the main thread (`Thread.Futex.Deadline.wait`) until the
        // scene-update watchdog (0x8BADF00D) kills the app. It must run off
        // the main thread. Feed it on a serial background queue (order
        // preserved) and hop back to main only for the Swift-side UI state.
        let workQueue = outputQueue
        workQueue.async { [weak self] in
            forwarded.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                let pointer = baseAddress.assumingMemoryBound(to: CChar.self)
                ghostty_surface_process_output(surface, pointer, UInt(buffer.count))
            }
            #if DEBUG
            // The DEBUG accessibility mirror uses the same queue for the same
            // lock-ordering reason as output processing.
            var accessibilityText: String?
            let snapshotNow = CACurrentMediaTime()
            if snapshotNow - workQueue.lastAccessibilityTextTime > 0.5 {
                workQueue.lastAccessibilityTextTime = snapshotNow
                accessibilityText = Self.accessibilitySurfaceText(surface)
            }
            #endif
            DispatchQueue.main.async {
                guard let self, !self.isDismantled else {
                    completion?(true)
                    return
                }
                guard self.surfaceGeneration == generation else {
                    completion?(false)
                    return
                }
                self.needsDraw = true
                if let cursorVisibilityDelta, cursorVisibilityDelta != self.hostCursorVisible {
                    self.hostCursorVisible = cursorVisibilityDelta
                    self.updateCursorOverlay()
                }
                #if DEBUG
                self.lastOutputAppliedTime = CACurrentMediaTime()
                #endif
                if !self.surfaceHasReceivedOutput {
                    self.surfaceHasReceivedOutput = true
                    self.snapshotFallbackView.isHidden = true
                    self.clearSnapshotFallbackVisual()
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
        guard let surface, !scrollToBottomInFlight else { return }
        scrollToBottomInFlight = true
        let generation = surfaceGeneration
        let action = "scroll_to_bottom"
        outputQueue.async { [weak self] in
            action.withCString { pointer in
                _ = ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
            }
            DispatchQueue.main.async {
                // Generation-guarded like the `processOutput` completion: a
                // stale pre-recovery completion must not clear the flag a
                // new-generation snap has since set.
                guard let self, self.surfaceGeneration == generation else { return }
                self.scrollToBottomInFlight = false
            }
        }
    }

    /// True while a `scroll_to_bottom` binding action is queued or running on
    /// the serial surface queue. Cleared on the reset path alongside the queue
    /// regeneration so a wedged surface cannot permanently disable the snap.
    private var scrollToBottomInFlight = false

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

    @objc
    func focusInput() {
        onFocusInputRequestedForTesting?()
        Self.activeInputSurface = self
        setNeedsGeometrySync()
        inputProxy.updateAccessoryLayoutInsets()
        inputProxy.becomeFirstResponder()
    }

    /// Resigns the currently focused terminal input proxy, if any.
    ///
    /// Use before presenting SwiftUI chrome so UIKit releases the hidden text
    /// input and terminal geometry can expand after the keyboard leaves.
    @discardableResult
    public static func resignActiveInput(surfaceID: String? = nil, sceneID: ObjectIdentifier? = nil) -> GhosttySurfaceInputFocusToken? {
        guard let surface = activeInputSurface else { return nil }
        if let sceneID, surface.window?.windowScene.map(ObjectIdentifier.init) != sceneID { return nil }
        if sceneID == nil, let surfaceID, surface.hostSurfaceID != surfaceID { return nil }
        let token = GhosttySurfaceInputFocusToken(view: surface)
        surface.resignInput()
        return token
    }
    public static func restoreInputFocus(
        _ token: GhosttySurfaceInputFocusToken?,
        surfaceID: String?
    ) -> Bool {
        guard let surfaceID,
              let view = token?.view,
              view.hostSurfaceID == surfaceID,
              view.window != nil, view.surface != nil, !view.isDismantled,
              !view.isHidden,
              view.alpha > 0.01 else {
            return false
        }
        view.focusInput()
        return true
    }

    /// Resigns this surface's hidden text input and clears keyboard geometry.
    public func resignInput() {
        inputProxy.resignFirstResponder()
        if Self.activeInputSurface === self {
            Self.activeInputSurface = nil
        }
        // Don't zero `keyboardHeight` here. `resignFirstResponder()` triggers
        // `keyboardWillHide`, which owns the full hide cleanup (proxy state,
        // docked-toolbar animation, geometry). Pre-zeroing would make that
        // handler's `keyboardHeight != 0` guard short-circuit, leaving the
        // toolbar at the old keyboard edge with a stale glyph.
    }

    /// Stops user-visible and accessibility output from a surface SwiftUI has removed.
    public func prepareForDismantle() {
        isDismantled = true
        prepareForReuseAfterDetach()
    }

    /// Quiesces the surface on window detach: resigns input, stops the display
    /// link, drops focus, and removes the debug accessibility carrier from the
    /// tree. Does not set ``isDismantled`` so a transient detach can re-attach
    /// and resume; only ``prepareForDismantle()`` marks the surface dead.
    private func prepareForReuseAfterDetach() {
        completePendingSurfaceOperations(returning: false)
        renderInFlight = false
        renderInFlightSince = nil
        needsAnotherRender = false
        resignInput()
        stopKeyboardHeightAnimation()
        stopDisplayLink()
        clearSnapshotFallbackVisual()
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
        // backlog drains before the free. (Retain the bridge across the hop; it
        // owns the userdata libghostty still references until the free.)
        enqueueSurfaceFree(surface, bridge: currentBridge, on: currentQueue)
    }

    private func enqueueSurfaceFree(
        _ surface: ghostty_surface_t,
        bridge: GhosttySurfaceBridge,
        on queue: GhosttySurfaceWorkQueue,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let retainedBridge = Unmanaged.passRetained(bridge)
        queue.async {
            ghostty_surface_free(surface)
            retainedBridge.release()
            if let completion {
                Task { @MainActor in completion() }
            }
        }
    }

    private func logRecoveryPausedDrop(kind: String, byteCount: Int? = nil) {
        let now = CACurrentMediaTime()
        guard now - lastRecoveryPausedDropLogTime >= 1 else { return }
        lastRecoveryPausedDropLogTime = now
        MobileDebugLog.anchormux(
            "render.recover.paused_drop kind=\(kind) bytes=\(byteCount ?? 0) pendingFrees=\(pendingSurfaceFreeCount)"
        )
    }

    @discardableResult
    private func pauseRenderPipelineRecovery(
        reason: String,
        stalledMs: Int
    ) -> Bool {
        MobileDebugLog.anchormux(
            "render.recover.paused reason=\(reason) stalledMs=\(stalledMs) pendingFrees=\(pendingSurfaceFreeCount)"
        )
        renderPipelineRecoveryPaused = true
        stopDisplayLink()
        _ = completePendingSurfaceOperations(returning: false)
        renderInFlight = false
        renderInFlightSince = nil
        needsAnotherRender = false
        needsDraw = false
        return true
    }

    private func resumePausedRenderPipelineRecoveryIfPossible() {
        guard renderPipelineRecoveryPaused,
              !isDismantled,
              surface != nil,
              pendingSurfaceFreeCount < Self.surfaceFreeBacklogRecoveryLimit else { return }
        MobileDebugLog.anchormux(
            "render.recover.resuming pendingFrees=\(pendingSurfaceFreeCount)"
        )
        renderPipelineRecoveryPaused = false
        _ = recoverRenderPipeline(
            reason: "free_drained",
            stalledMs: 0,
            replay: .delegateWhenNoCaller
        )
    }

    @discardableResult
    private func recoverRenderPipeline(
        reason: String,
        stalledMs: Int,
        replay: RenderPipelineRecoveryReplay
    ) -> Bool {
        guard !isDismantled,
              surface != nil else {
            return false
        }
        guard !renderPipelineRecoveryPaused else {
            return pauseRenderPipelineRecovery(reason: reason, stalledMs: stalledMs)
        }
        if pendingSurfaceFreeCount >= Self.surfaceFreeBacklogRecoveryLimit {
            return pauseRenderPipelineRecovery(reason: reason, stalledMs: stalledMs)
        }
        if pendingSurfaceFreeCount >= Self.surfaceFreeBacklogWarningThreshold {
            MobileDebugLog.anchormux(
                "render.recover.free_backlog reason=\(reason) stalledMs=\(stalledMs) pendingFrees=\(pendingSurfaceFreeCount)"
            )
        }
        MobileDebugLog.anchormux(
            "render.recover reason=\(reason) stalledMs=\(stalledMs) generation=\(surfaceGeneration) pendingFrees=\(pendingSurfaceFreeCount)"
        )
        let completedFailedOperation = completePendingSurfaceOperations(returning: false)
        let targetGeneration = surfaceGeneration &+ 1
        let capturedFallback = captureSnapshotFallbackForRecovery()

        stopDisplayLink()
        let oldSurface = surface
        let oldBridge = bridge
        let oldQueue = outputQueue
        oldBridge.detach()
        requestSnapshotFallbackTextForRecovery(
            surface: oldSurface,
            on: oldQueue,
            targetGeneration: targetGeneration
        )
        if let oldSurface {
            GhosttySurfaceView.unregister(surface: oldSurface)
            pendingSurfaceFreeCount += 1
            enqueueSurfaceFree(oldSurface, bridge: oldBridge, on: oldQueue) { [weak self] in
                guard let self else { return }
                self.pendingSurfaceFreeCount = max(0, self.pendingSurfaceFreeCount - 1)
                MobileDebugLog.anchormux(
                    "render.recover.free_drained pendingFrees=\(self.pendingSurfaceFreeCount)"
                )
                self.resumePausedRenderPipelineRecoveryIfPossible()
            }
        }

        surface = nil
        renderInFlight = false
        renderInFlightSince = nil
        needsAnotherRender = false
        needsDraw = true
        cellPixelSize = .zero
        lastRenderRect = .zero
        lastRenderLayoutViewportHeight = nil
        lastRenderHasSourceLayoutViewport = false
        lastAppliedContentScale = 0

        surfaceGeneration = targetGeneration
        outputQueueGeneration &+= 1
        outputQueue = GhosttySurfaceWorkQueue(generation: outputQueueGeneration)
        scrollToBottomInFlight = false
        bridge = GhosttySurfaceBridge()
        bridge.attach(to: self)

        initializeSurface()
        if capturedFallback {
            flushSnapshotFallbackPresentation()
        }
        if replay == .delegateWhenNoCaller && !completedFailedOperation {
            delegate?.ghosttySurfaceViewDidResetRenderPipeline(self)
        }
        return true
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

    private func initializeSurface() {
        guard let app = runtime?.app else { return }
        surface = makeSurface(app: app)
        if let surface {
            GhosttySurfaceView.register(surface: surface, for: self)
            if let config = runtime?.config {
                applyBackgroundColorFromConfig(config)
            }
            // A new surface starts empty. Keep any recovery snapshot visible until
            // real terminal bytes reach this generation, otherwise reconnect or
            // render recovery briefly erases the user's last visible terminal.
            surfaceHasReceivedOutput = false
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
        cursorBlinkState.start(now: CACurrentMediaTime())
        needsDraw = true
        updateCursorOverlay()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        cursorOverlayLayer?.isHidden = true
    }

    /// Shared reaction to user-produced terminal input (typing, backspace,
    /// escape sequences, paste): restart the cursor blink and optimistically
    /// snap the local mirror to the bottom of scrollback. The mirror is
    /// display-only — the Mac echoes input at the prompt — so a user who types
    /// while scrolled up would otherwise keep looking at old scrollback and
    /// read the terminal as frozen. Passive output never forces this jump;
    /// only explicit user input does (plus the one-time initial-output scroll
    /// in `scrollInitialOutputToBottomIfNeeded`).
    private func handleUserProducedInput() {
        resetCursorBlink()
        // A flick still decelerating would fight the snap: deltas already in
        // `pendingScrollLines` flush on the display-link frame AFTER the snap
        // below, and UIScrollView momentum keeps producing more. Drop the
        // pending deltas and freeze the scroll mechanics at the current offset
        // (kill-deceleration idiom) so typed input lands at the bottom.
        pendingScrollLines = 0
        scrollMechanicsView.setContentOffset(scrollMechanicsView.contentOffset, animated: false)
        enqueueScrollToBottom()
    }

    /// Reset cursor to visible and restart blink cycle (call on user input).
    private func resetCursorBlink() {
        guard surface != nil else { return }
        cursorBlinkState.reset(now: CACurrentMediaTime())
        needsDraw = true
        updateCursorOverlay()
    }

    @objc func handleDisplayLinkFire() {
        let now = CACurrentMediaTime()
        if checkSurfaceOperationDeadlines(now: now) {
            return
        }
        guard surface != nil else {
            if !hasPendingSurfaceOperationDeadline {
                stopDisplayLink()
            }
            return
        }
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
        advanceKeyboardHeightAnimation()
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
        let blinkChanged = cursorBlinkState.advance(now: now)
        // Draw on content/cursor changes, and for a short bounded burst after
        // any geometry change. iOS has no renderer-side vsync, so a frame is
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
        if needsDraw || blinkChanged || geometrySettling {
            needsDraw = false
            requestRender()
            updateCursorOverlay()
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
                    MobileDebugLog.anchormux("zoom.report grid=\(pending.columns)x\(pending.rows) id=\(viewportReportID)")
                    delegate?.ghosttySurfaceView(self, didResize: pending, reportID: viewportReportID)
                }
            }
        }

        // Flush coalesced scroll to the Mac at most once per frame.
        flushPendingScrollIfNeeded()

        // Fade the zoom HUD once interaction has been quiet. Uses real elapsed
        // time off the continuous display link (no timer / sleep).
        if zoomOverlayShown,
           now - zoomOverlayLastInteraction > Self.zoomOverlayVisibleDuration {
            fadeOutZoomOverlay()
        }
    }

    /// Drive a full render cycle via `ghostty_surface_render_now`, dispatched
    /// to the off-main surface queue.
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
    private func requestRender() {
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
              !isDismantled else { return }
        // Coalesce: never let more than one render_now sit on the serial queue.
        // (Called on main from the display link.)
        if renderInFlight {
            needsAnotherRender = true
            return
        }
        renderInFlight = true
        renderInFlightSince = CACurrentMediaTime()
        let generation = surfaceGeneration
        let enqueuedAt = CACurrentMediaTime()
        outputQueue.async { [weak self] in
            // Queue LAG = how long this render waited behind other ops. If this
            // climbs into hundreds of ms the queue is backlogged (the freeze).
            let lagMs = (CACurrentMediaTime() - enqueuedAt) * 1000
            if lagMs > 150 { MobileDebugLog.anchormux("oq.render.LAG \(Int(lagMs))ms") }
            ghostty_surface_render_now(surface)
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.surfaceGeneration == generation else { return }
                self.renderInFlight = false
                self.renderInFlightSince = nil
                guard !self.isDismantled else {
                    self.needsAnotherRender = false
                    return
                }
                if self.needsAnotherRender {
                    self.needsAnotherRender = false
                    self.requestRender()
                }
            }
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

    private func updateCursorOverlay() {
        guard let surface,
              hostCursorVisible,
              window != nil,
              !isHidden,
              alpha > 0.01,
              !lastRenderRect.isEmpty,
              cellPixelSize.width > 0,
              cellPixelSize.height > 0 else {
            cursorOverlayLayer?.isHidden = true
            return
        }
        let overlay = ensureCursorOverlayLayer()
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let scale = max(preferredScreenScale, 1)
        overlay.contentsScale = scale
        let cellWidth = max(cellPixelSize.width / scale, 1)
        let cellHeight = max(CGFloat(height), cellPixelSize.height / scale, 1)
        let cursorWidth = max(1.0 / scale, min(CGFloat(1.5), cellWidth))
        let cursorX = lastRenderRect.minX + CGFloat(x) - (cellWidth / 2)
        let cursorY = lastRenderRect.minY + CGFloat(y) - cellHeight
        overlay.frame = CGRect(
            x: floor(cursorX),
            y: floor(cursorY),
            width: cursorWidth,
            height: ceil(cellHeight)
        )
        overlay.backgroundColor = cursorBlinkState.isVisible
            ? (configCursorColor ?? UIColor(red: 0xc0/255.0, green: 0xc1/255.0, blue: 0xb5/255.0, alpha: 1.0)).cgColor
            : (configBackgroundColor ?? backgroundColor ?? .black).cgColor
        overlay.isHidden = false
    }

    private func ensureCursorOverlayLayer() -> CALayer {
        if let cursorOverlayLayer {
            return cursorOverlayLayer
        }
        let layer = CALayer()
        layer.name = "cmux.cursorOverlay"
        layer.zPosition = 1001
        layer.actions = [
            "backgroundColor": NSNull(),
            "bounds": NSNull(),
            "frame": NSNull(),
            "position": NSNull(),
        ]
        self.layer.addSublayer(layer)
        cursorOverlayLayer = layer
        return layer
    }

    private(set) var configBackgroundColor: UIColor?
    private(set) var configCursorColor: UIColor?

    private func applyBackgroundColorFromConfig(_ config: ghostty_config_t) {
        // The view background (the area behind/around the cells and the letterbox
        // fill) follows the synced theme store, not this config read. On the
        // process-singleton runtime the baked `ghostty_config_t` can be stale
        // across a theme change, so reading the background from it would leave the
        // local background on the old theme's color (the reported bug). The theme
        // store is updated on connect and on a live theme change, so it is the
        // authoritative source for what color the user should see here.
        let themeBackground = GhosttyRuntime.currentBackgroundUIColor
        backgroundColor = themeBackground
        snapshotFallbackView.backgroundColor = themeBackground
        configBackgroundColor = themeBackground
        #if DEBUG
        var bgColor = ghostty_config_color_s()
        let bgKey = "background"
        if ghostty_config_get(config, &bgColor, bgKey, UInt(bgKey.lengthOfBytes(using: .utf8))) {
            log.debug("applyBg: theme bg -> UIColor(\(themeBackground.debugDescription, privacy: .public)); config bg r=\(bgColor.r, privacy: .public) g=\(bgColor.g, privacy: .public) b=\(bgColor.b, privacy: .public)")
        } else {
            log.debug("applyBg: theme bg -> UIColor(\(themeBackground.debugDescription, privacy: .public)); config bg unavailable")
        }
        #endif
        var fgColor = ghostty_config_color_s()
        let fgKey = "foreground"
        if ghostty_config_get(config, &fgColor, fgKey, UInt(fgKey.lengthOfBytes(using: .utf8))) {
            snapshotFallbackView.textColor = UIColor(red: CGFloat(fgColor.r) / 255.0, green: CGFloat(fgColor.g) / 255.0, blue: CGFloat(fgColor.b) / 255.0, alpha: 1.0)
        }
        var cursorColor = ghostty_config_color_s()
        let cursorKey = "cursor-color"
        if ghostty_config_get(config, &cursorColor, cursorKey, UInt(cursorKey.lengthOfBytes(using: .utf8))) {
            configCursorColor = UIColor(
                red: CGFloat(cursorColor.r) / 255.0,
                green: CGFloat(cursorColor.g) / 255.0,
                blue: CGFloat(cursorColor.b) / 255.0,
                alpha: 1.0
            )
        }
    }

    /// Re-applies the current theme's colors to this surface's local view: the
    /// view/letterbox background and snapshot-fallback colors from the theme
    /// store, and the cursor-overlay color from the (freshly rebuilt) runtime
    /// config. Called on a live theme change so an already-mounted surface
    /// recolors its background in place — libghostty has no API to recolor a live
    /// surface's *view* background, and the runtime config is only re-read here.
    @MainActor
    func refreshThemeColors() {
        let themeBackground = GhosttyRuntime.currentBackgroundUIColor
        backgroundColor = themeBackground
        snapshotFallbackView.backgroundColor = themeBackground
        configBackgroundColor = themeBackground
        if let config = runtime?.config {
            applyBackgroundColorFromConfig(config)
        }
        inputProxy.refreshThemeColors()
        updateCursorOverlay()
        needsDraw = true
    }

    /// Re-applies the active theme to every registered surface's local view after
    /// a live theme change. Pairs with ``GhosttyRuntime/rebuildConfigFromStore()``,
    /// which feeds the new config to the renderer; this updates the surrounding
    /// UIKit colors the renderer does not own.
    @MainActor
    static func refreshAllSurfacesForThemeChange() {
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
        for view in registeredSurfaceViews.values.compactMap(\.value) {
            view.refreshThemeColors()
        }
    }

    private func setFocus(_ focused: Bool) {
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
        if visible {
            updateCursorOverlay()
        } else {
            cursorOverlayLayer?.isHidden = true
        }
    }

    /// Re-arm the debounced viewport report after a round-trip returned no
    /// effective grid, so a transient RPC drop does not leave the render pinned
    /// to a stale effective grid (the "stuck letterbox" freeze). Bounded and
    /// display-link driven (the existing settle machinery re-fires it); a
    /// confirmed `applyViewSize` resets the counter. No-op once the cap is hit.
    public func retryViewportReport() {
        guard viewportReportRetries < Self.maxViewportReportRetries,
              let pending = lastReportedSize, pending.columns > 0, pending.rows > 0 else { return }
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
        let sourceLayoutViewportHeight: CGFloat
        /// Pinned render size in points when letterboxed to an effective
        /// grid; nil means fill the container.
        let pinnedSize: CGSize?
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
        // Reserve, from the bottom up, the keyboard/safe-area inset (keyboard
        // height when up, else the bottom safe area so the always-visible toolbar
        // clears the home indicator), the open composer band, and the persistent
        // toolbar: the surface owns the whole bottom dock in one coordinate system,
        // so the grid shrinks by all three. The order is immaterial to the reserved
        // total; only the frame positions in `bottomDockFrames()` encode the
        // `terminal / toolbar / composer / keyboard` stack. While the HIDE button
        // has suppressed the chrome (`chromeHidden`) the toolbar is off screen and
        // reserves nothing and the composer band is hidden, so the grid reclaims the
        // whole height including the bottom safe area, matching `bottomDockFrames()`
        // pinning the dock to `bounds.height`; only an actual keyboard is reserved
        // then if one is somehow still up.
        //
        // The reservation + container math is the host-tested
        // `TerminalLetterboxGeometry.terminalContainerSize` (the same arithmetic
        // that was inlined here), so the keyboard open/closed full-height contract
        // is locked by a unit test and the surface cannot drift from it. Passing
        // the CURRENT `keyboardHeight` means a keyboard-down sync never inherits a
        // stale keyboard value (the "terminal not full height when keyboard closed"
        // bug); the safe-area inset is resolved from the window when the view inset
        // is a stale 0 right after the keyboard hides (see `safeAreaInsetsBottom`).
        let snapshot = viewportSnapshot()
        let container = snapshot.containerSize
        let containerW = container.width
        let containerH = container.height
        let containerPxW = UInt32(max(1, Int((containerW * scale).rounded(.down))))
        let containerPxH = UInt32(max(1, Int((containerH * scale).rounded(.down))))
        let eff = effectiveGrid
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
                let pinnedW = CGFloat(eff.cols) * cell.width / scale
                let pinnedH = CGFloat(eff.rows) * cell.height / scale
                if !fillsNaturalGrid, !withinOneCell, pinnedW + 0.5 < containerW || pinnedH + 0.5 < containerH {
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
                sourceLayoutViewportHeight: snapshot.layoutViewportRect.height,
                pinnedSize: pinnedSize
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
        lastRenderLayoutViewportHeight = result.sourceLayoutViewportHeight
        lastRenderHasSourceLayoutViewport = true
        let renderRect = snapshot.renderRect(
            forRenderSize: measuredRenderRect.size,
            clampsStaleLiveViewport: shouldClampStaleLiveViewport(using: snapshot)
        )
        lastRenderRect = renderRect
        #if DEBUG
        recordBottomViewportMismatchIfNeeded()
        #endif
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
        updateCursorOverlay()
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
        // Stretch-to-fill: keep the RENDERED font tracking the daemon-granted
        // rows so a Mac-constrained grid fills the phone instead of parking a
        // letterbox band above the content.
        autoFitFontToEffectiveRows(
            renderedRows: naturalSize.rows,
            containerPixelHeight: containerH * scale,
            cellPixelHeight: result.cellPixelSize.height
        )
        // Report the row CAPACITY at the user's base font, not the rendered
        // rows: a report derived from the fitted font would ratchet the
        // negotiated minimum down and the phone could never learn when the
        // constraining device grew back. Columns stay at the rendered font
        // (the PTY must never be wider than the rendered grid can show).
        let reportGrid = capacityReportGrid(
            for: naturalSize,
            containerPixelHeight: containerH * scale,
            cellPixelHeight: result.cellPixelSize.height
        )
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
    }

    /// The viewport report for the current geometry: rendered columns plus the
    /// base-font row capacity (see `TerminalRowCapacityFit.capacityRows`).
    private func capacityReportGrid(
        for natural: TerminalGridSize,
        containerPixelHeight: CGFloat,
        cellPixelHeight: CGFloat
    ) -> TerminalGridSize {
        guard let fit = TerminalRowCapacityFit(
            containerPixelHeight: containerPixelHeight,
            cellPixelHeight: cellPixelHeight,
            liveFontSize: liveFontSize
        ), let capacity = fit.capacityRows(atBaseFontSize: userBaseFontSize) else { return natural }
        return TerminalGridSize(
            columns: natural.columns,
            rows: capacity,
            pixelWidth: natural.pixelWidth,
            pixelHeight: natural.pixelHeight
        )
    }

    /// Re-derive the rendered font from the effective grid: raise it so a
    /// smaller granted row count fills the container, decay it back toward the
    /// user's base font when the grant returns to (or past) capacity or the
    /// pin lifts. Floored at the user's base font — the fit only ever
    /// stretches, and a stale oversized grant during a keyboard transition
    /// steps to base instead of collapsing the font toward the minimum.
    private func autoFitFontToEffectiveRows(
        renderedRows: Int,
        containerPixelHeight: CGFloat,
        cellPixelHeight: CGFloat
    ) {
        // Never fight an in-flight explicit zoom step.
        guard pendingFontSize == nil else { return }
        guard let eff = effectiveGrid else {
            if abs(liveFontSize - userBaseFontSize) >= 0.25 {
                MobileDebugLog.anchormux("zoom.autofit.decay live=\(liveFontSize) base=\(userBaseFontSize)")
                applyAbsoluteFontSize(userBaseFontSize)
            }
            return
        }
        guard TerminalRowCapacityFit.shouldRefit(renderedRows: renderedRows, effectiveRows: eff.rows),
              let fit = TerminalRowCapacityFit(
                  containerPixelHeight: containerPixelHeight,
                  cellPixelHeight: cellPixelHeight,
                  liveFontSize: liveFontSize
              ),
              let target = fit.fitFontSize(forEffectiveRows: eff.rows) else { return }
        let clamped = min(max(target, userBaseFontSize), MobileTerminalFontPreference.maximumSize)
        guard abs(clamped - liveFontSize) >= 0.25 else { return }
        MobileDebugLog.anchormux(
            "zoom.autofit eff=\(eff.cols)x\(eff.rows) rendered=\(renderedRows) font \(liveFontSize)->\(clamped)"
        )
        applyAbsoluteFontSize(clamped)
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
        layer.contentsScale = scale
        for sublayer in layer.sublayers ?? [] where isGhosttyRendererLayer(sublayer) {
            if sublayer.frame != renderRect {
                sublayer.frame = renderRect
            }
            if sublayer.bounds.size != renderRect.size {
                sublayer.bounds = CGRect(origin: .zero, size: renderRect.size)
            }
            sublayer.contentsScale = scale
        }
        CATransaction.commit()
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

    private func isGhosttyRendererLayer(_ layer: CALayer) -> Bool {
        String(describing: type(of: layer)) == "IOSurfaceLayer"
    }

    private func logLayerTree(reason: String) {
        let hostLayer = layer
        let hostSummary = "\(type(of: hostLayer)) bounds=\(hostLayer.bounds.integral.debugDescription) frame=\(hostLayer.frame.integral.debugDescription) contentsScale=\(hostLayer.contentsScale)"
        let childSummaries = (hostLayer.sublayers ?? []).prefix(4).enumerated().map { index, sublayer in
            "\(index):\(type(of: sublayer)) bounds=\(sublayer.bounds.integral.debugDescription) frame=\(sublayer.frame.integral.debugDescription) hidden=\(sublayer.isHidden) contents=\(sublayer.contents != nil) scale=\(sublayer.contentsScale)"
        }.joined(separator: " | ")
        MobileDebugLog.anchormux("surface.layers reason=\(reason) host=\(hostSummary) children=[\(childSummaries)] fallbackHidden=\(snapshotFallbackView.isHidden) fallbackChars=\((snapshotFallbackView.text ?? "").count)")
    }

    private func makeSurface(app: ghostty_app_t) -> ghostty_surface_t? {
        var surfaceConfig = ghostty_surface_config_new()
        let bridgePointer = Unmanaged.passUnretained(bridge).toOpaque()
        surfaceConfig.userdata = bridgePointer
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_IOS
        surfaceConfig.platform = ghostty_platform_u(
            ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(self).toOpaque())
        )
        surfaceConfig.scale_factor = preferredScreenScale
        surfaceConfig.font_size = liveFontSize
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        surfaceConfig.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        surfaceConfig.io_write_cb = { userdata, buf, len in
            guard let userdata, let buf, len > 0 else { return }
            let data = Data(bytes: buf, count: Int(len))
            let bridge = Unmanaged<GhosttySurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                bridge.surfaceView?.handleOutboundBytes(data)
            }
        }
        surfaceConfig.io_write_userdata = bridgePointer
        return ghostty_surface_new(app, &surfaceConfig)
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
        snapshotFallbackView.attributedText?.string ?? snapshotFallbackView.text ?? ""
    }

    func visibleSnapshotAttributedTextForTesting() -> NSAttributedString? {
        snapshotFallbackView.attributedText
    }

    func isUsingSnapshotFallbackForTesting() -> Bool {
        !snapshotFallbackView.isHidden || snapshotFallbackVisualView != nil
    }

    private func syncSnapshotFallback() {
        // Once the Metal renderer is active (surface has received output),
        // keep the fallback hidden so the IOSurfaceLayer is visible.
        if surfaceHasReceivedOutput {
            snapshotFallbackView.isHidden = true
            clearSnapshotFallbackVisual()
            return
        }

        let rendererHasContents = !prefersSnapshotFallbackRendering &&
            (layer.sublayers ?? []).contains(where: isGhosttyRendererLayerVisible)
        if rendererHasContents {
            snapshotFallbackView.isHidden = true
            clearSnapshotFallbackVisual()
            return
        }

        _ = updateSnapshotFallback(
            text: lastRecoverySnapshotText,
            html: lastSnapshotFallbackHTML,
            clearWhenEmpty: true
        )
        requestLiveSnapshotFallbackIfNeeded()
    }

    @discardableResult
    private func captureSnapshotFallbackForRecovery() -> Bool {
        let capturedVisual = captureVisualSnapshotFallbackForRecovery()
        let visibleText = snapshotFallbackView.isHidden
            ? ""
            : (snapshotFallbackView.attributedText?.string ?? snapshotFallbackView.text ?? "")
        let capturedText: Bool
        if visibleText.isEmpty {
            lastRecoverySnapshotText = ""
            capturedText = false
        } else {
            lastRecoverySnapshotText = visibleText
            capturedText = updateSnapshotFallback(
                text: visibleText,
                html: lastSnapshotFallbackHTML,
                clearWhenEmpty: false
            )
        }
        return capturedVisual || capturedText
    }

    @discardableResult
    private func captureVisualSnapshotFallbackForRecovery() -> Bool {
        guard !bounds.isEmpty,
              let visual = snapshotView(afterScreenUpdates: false) else {
            return false
        }
        clearSnapshotFallbackVisual()
        visual.frame = snapshotFallbackView.frame.isEmpty ? bounds : snapshotFallbackView.frame
        visual.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        visual.isUserInteractionEnabled = false
        visual.layer.zPosition = 900
        addSubview(visual)
        snapshotFallbackVisualView = visual
        bringSubviewToFront(snapshotFallbackView)
        return true
    }

    private func clearSnapshotFallbackVisual() {
        snapshotFallbackVisualView?.removeFromSuperview()
        snapshotFallbackVisualView = nil
    }

    private func requestSnapshotFallbackTextForRecovery(
        surface oldSurface: ghostty_surface_t?,
        on oldQueue: GhosttySurfaceWorkQueue,
        targetGeneration: UInt64
    ) {
        guard let oldSurface else { return }
        oldQueue.async {
            let snapshot = Self.surfaceText(oldSurface, pointTag: GHOSTTY_POINT_VIEWPORT)
            guard let snapshot, !snapshot.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isDismantled,
                      self.surfaceGeneration == targetGeneration,
                      !self.surfaceHasReceivedOutput else {
                    return
                }
                self.lastRecoverySnapshotText = snapshot
                self.lastSnapshotFallbackHTML = nil
                if self.updateSnapshotFallback(text: snapshot, html: nil, clearWhenEmpty: false) {
                    self.flushSnapshotFallbackPresentation()
                }
            }
        }
    }

    @discardableResult
    func updateSnapshotFallback(text snapshot: String, html: String?, clearWhenEmpty: Bool) -> Bool {
        guard !snapshot.isEmpty else {
            if clearWhenEmpty {
                lastSnapshotFallbackHTML = nil
                snapshotFallbackView.attributedText = nil
                snapshotFallbackView.text = ""
                snapshotFallbackView.isHidden = true
            }
            return false
        }

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

        if (snapshotFallbackView.text ?? "") != snapshot && snapshotFallbackView.attributedText == nil {
            snapshotFallbackView.text = snapshot
        }

        let visibleTextLength = snapshotFallbackView.attributedText?.string.utf16.count ?? (snapshotFallbackView.text ?? "").utf16.count
        if visibleTextLength > 0 {
            snapshotFallbackView.scrollRangeToVisible(NSRange(location: max(0, visibleTextLength - 1), length: 1))
        }
        snapshotFallbackView.isHidden = false
        clearSnapshotFallbackVisual()
        flushSnapshotFallbackPresentation()
        return true
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
            snapshotFallbackView.backgroundColor = .black
            return
        }

        let probeIndex = firstVisibleThemeAttributeIndex(in: attributedText)
        if let background = attributedText.attribute(.backgroundColor, at: probeIndex, effectiveRange: nil) as? UIColor {
            snapshotFallbackView.backgroundColor = background
        } else {
            snapshotFallbackView.backgroundColor = .black
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

    private func isGhosttyRendererLayerVisible(_ layer: CALayer) -> Bool {
        isGhosttyRendererLayer(layer) && layer.contents != nil
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

    /// "What the user sees": the visible viewport text of every on-screen
    /// terminal surface, for the DEV "Copy Debug Logs" action so a bug report
    /// pairs the on-screen content with the debug log. Reads the VIEWPORT
    /// (visible grid only, not scrollback) via libghostty.
    public static let visibleTerminalSnapshot: @MainActor () async -> String = {
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
        // Collect the main-actor state + surface pointers first, then read the
        // viewport text on the serial output queue. `ghostty_surface_read_text`
        // takes the same surface lock as `process_output` (which runs off-main);
        // reading it on the MAIN thread here contends that lock during a render
        // storm and stalls the present — tapping Copy Debug Logs would itself
        // blank the terminal. The output queue is never concurrent with
        // `process_output`, so the read can't wedge. The await is bounded by
        // the surface's display-link deadline so this diagnostic path does not
        // add a sleeping timer task or block the main actor.
        var pending: [VisibleSnapshotRequest] = []
        for view in registeredSurfaceViews.values.compactMap(\.value) {
            guard view.window != nil, !view.isHidden, view.alpha > 0.01,
                  let surface = view.surface else { continue }
            let grid = view.effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "?"
            pending.append(VisibleSnapshotRequest(
                view: view,
                grid: grid,
                font: Int(view.liveFontSize),
                surface: surface,
                generation: view.surfaceGeneration
            ))
        }
        if pending.isEmpty {
            return "===== visible terminal: (no on-screen surface) ====="
        }
        var sections: [String] = []
        for item in pending {
            guard let section = await item.view.visibleSnapshotSection(
                surface: item.surface,
                generation: item.generation,
                grid: item.grid,
                font: item.font
            ) else {
                return "===== visible terminal: (snapshot skipped — render busy) ====="
            }
            sections.append(section)
        }
        return sections.joined(separator: "\n\n")
    }

    private func visibleSnapshotSection(
        surface: ghostty_surface_t,
        generation: UInt64,
        grid: String,
        font: Int
    ) async -> String? {
        guard self.surface == surface,
              surfaceGeneration == generation,
              !renderPipelineRecoveryPaused else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            let operationID = makeSurfaceOperationID()
            if let existing = pendingVisibleSnapshot {
                pendingVisibleSnapshot = nil
                existing.continuation.resume(returning: nil)
            }
            pendingVisibleSnapshot = PendingVisibleSnapshot(
                id: operationID,
                startedAt: CACurrentMediaTime(),
                continuation: continuation
            )
            ensureSurfaceOperationDeadlinePump()
            let queue = outputQueue
            let read = VisibleSnapshotRead(surface: surface, generation: generation, grid: grid, font: font)
            queue.async {
                let text = Self.surfaceText(read.surface, pointTag: GHOSTTY_POINT_VIEWPORT) ?? "(unavailable)"
                let section = "===== visible terminal · grid=\(read.grid) · font=\(read.font) =====\n"
                    + text
                Task { @MainActor [weak self] in
                    guard let view = self else { return }
                    guard view.surface == read.surface,
                          view.surfaceGeneration == read.generation else {
                        view.completePendingVisibleSnapshot(id: operationID, returning: nil)
                        return
                    }
                    view.completePendingVisibleSnapshot(id: operationID, returning: section)
                }
            }
        }
    }

    private func handleBell() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        NotificationCenter.default.post(
            name: .ghosttySurfaceDidRingBell,
            object: self
        )
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
}

nonisolated private enum RenderPipelineRecoveryReplay {
    case callerWillRequestReplay
    case delegateWhenNoCaller
}

/// One output/geometry operation awaiting either its output-queue completion or
/// the display-link deadline that rebuilds the stalled render pipeline.
nonisolated private struct PendingSurfaceOperation {
    let id: UInt64
    let startedAt: CFTimeInterval
    let byteCount: Int?
    let continuation: CheckedContinuation<Bool, Never>
}

/// One visible-terminal snapshot read awaiting output-queue completion or its
/// display-link deadline. A timeout skips only the diagnostic snapshot.
nonisolated private struct PendingVisibleSnapshot {
    let id: UInt64
    let startedAt: CFTimeInterval
    let continuation: CheckedContinuation<String?, Never>
}

/// One "View as Text" read awaiting output-queue completion or deadline.
nonisolated private struct PendingCopyableTextRead {
    let id: UInt64
    let startedAt: CFTimeInterval
    let cancellation: SurfaceOperationCancellationToken
    let continuation: CheckedContinuation<String?, Never>

    func cancel() {
        cancellation.cancel()
    }
}

/// One surface's request for the bounded visible-terminal snapshot.
nonisolated private struct VisibleSnapshotRequest {
    let view: GhosttySurfaceView
    let grid: String
    let font: Int
    let surface: ghostty_surface_t
    let generation: UInt64
}

/// Raw surface read payload captured by the off-main output queue.
///
/// The C surface pointer is dereferenced only on `GhosttySurfaceWorkQueue`,
/// which is the same FIFO queue that owns `process_output` and surface free.
nonisolated private struct VisibleSnapshotRead: @unchecked Sendable {
    let surface: ghostty_surface_t
    let generation: UInt64
    let grid: String
    let font: Int
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
