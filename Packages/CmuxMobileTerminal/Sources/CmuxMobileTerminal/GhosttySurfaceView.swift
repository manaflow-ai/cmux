#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileGhosttyEngine
import CmuxMobileTerminalKit
import OSLog
import UIKit

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "ghostty.surface")

// lint:allow namespace-enum — file-local DEBUG input-trace logger on the off-limits typing-latency render path; type reshape deferred to the GhosttySurfaceView UI-god-object split wave.
enum TerminalInputDebugLog {
    private static let isEnabled = ProcessInfo.processInfo.environment["CMUX_INPUT_DEBUG"] == "1"
    private static let logger = Logger(subsystem: "ai.manaflow.cmux.ios", category: "ghostty.input")

    static func log(_ message: String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        #endif
        guard isEnabled else { return }
        logger.debug("input: \(message, privacy: .public)")
    }

    static func textSummary(_ text: String) -> String {
        let summary = String(reflecting: text)
        guard summary.count > 96 else { return summary }
        return "\(summary.prefix(96))..."
    }

    static func dataSummary(_ data: Data) -> String {
        let prefix = data.prefix(32)
        let prefixData = Data(prefix)
        let hex = prefix.map { String(format: "%02X", $0) }.joined(separator: " ")
        let utf8 = String(data: prefixData, encoding: .utf8) ?? "<non-utf8>"
        let suffix = data.count > prefix.count ? " ..." : ""
        return "len=\(data.count) hex=\(hex)\(suffix) utf8=\(textSummary(utf8))"
    }
}

@MainActor
public protocol GhosttySurfaceViewDelegate: AnyObject {
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data)
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize)
    /// Forward a scroll gesture to the Mac's real surface. `lines` is signed
    /// (sign = direction), `col`/`row` is the grid cell under the finger (so
    /// alt-screen mouse-wheel reports at the right cell). Optional.
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didScrollLines lines: Double, atCol col: Int, row: Int)
    /// Forward a tap to the Mac's real surface as a left click at the given grid
    /// cell, so TUIs with mouse reporting (lazygit/htop/fzf) receive the click.
    /// The Mac's libghostty self-gates: a normal screen treats it as a harmless
    /// empty selection. Optional.
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didTapAtCol col: Int, row: Int)
}

public extension GhosttySurfaceViewDelegate {
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didScrollLines lines: Double, atCol col: Int, row: Int) {}
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didTapAtCol col: Int, row: Int) {}
}

@MainActor
protocol TerminalSurfaceHosting: AnyObject {
    var currentGridSize: TerminalGridSize { get }
    func processOutput(_ data: Data)
    func focusInput()
    /// Apply the daemon's authoritative rendering grid. Unconditional —
    /// implementations render at exactly cols × rows and letterbox any
    /// remaining container area. The daemon broadcasts this on every
    /// attach/resize/detach/open, plus inlined in RPC responses, so
    /// every attached device converges on the same grid.
    func applyViewSize(cols: Int, rows: Int)
    #if DEBUG
    var onOutputProcessedForTesting: (() -> Void)? { get set }
    func accessibilityRenderedTextForTesting() -> String?
    #endif
}

extension TerminalSurfaceHosting {
    func focusInput() {}
    func applyViewSize(cols _: Int, rows _: Int) {}
    #if DEBUG
    var onOutputProcessedForTesting: (() -> Void)? {
        get { nil }
        set {}
    }
    func accessibilityRenderedTextForTesting() -> String? { nil }
    #endif
}

public final class GhosttySurfaceView: UIView, TerminalSurfaceHosting {
    private weak var engine: GhosttyEngineService?
    private weak var registry: GhosttySurfaceRegistry?
    private weak var delegate: GhosttySurfaceViewDelegate?
    private let fontSize: Float32
    /// Surface-owned live font size (points). Zoom mutates this; it is the
    /// source of truth for the current size, so the size accumulates correctly
    /// across taps even though the actual libghostty apply is coalesced.
    private var liveFontSize: Float32
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
    /// `zoomOverlayVisibleDuration`. Time-based off the per-frame callback, not a
    /// timer/`Task.sleep`, so it honors the no-sleep rule and tracks real
    /// elapsed time regardless of frame rate.
    private var zoomOverlayLastInteraction: CFTimeInterval = 0
    private static let zoomOverlayVisibleDuration: CFTimeInterval = 2.5
    /// Persisted user "default zoom" backing the zoom-control overlay's
    /// reset/save/restore actions. Owned by the surface (constructed at init)
    /// rather than reached through a singleton, so it is injectable in tests.
    private let zoomPreference = MobileTerminalZoomPreference()
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
    private var needsAnotherRender: Bool = false
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
    private var surfaceHasReceivedOutput: Bool = false
    private var shouldScrollInitialOutputToBottom = true
    #if DEBUG
    private var lastInputTimestamp: CFTimeInterval = 0
    private var latencySamples: [Double] = []
    var onOutputProcessedForTesting: (() -> Void)?
    /// DEBUG seam for the latency probe: fires on the main actor each time a
    /// `ghostty_surface_render_now` round-trip completes (the moment the
    /// rendered frame's main-thread completion hop lands). Paired with
    /// `onOutputProcessedForTesting`, this bounds keystroke→pixels latency
    /// without touching the render path itself.
    var onRenderCompletedForTesting: (() -> Void)?
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

    /// The engine session owning this surface's blocking libghostty calls.
    private(set) var session: GhosttySurfaceSession?
    /// The surface's registry identity, for unregistration on dispose.
    private var surfaceIdentity: UInt?
    /// Single main-actor consumer of the surface's ordered host-event stream
    /// (output-applied, render-completed, geometry, title, bell, close, …).
    private var hostEventTask: Task<Void, Never>?
    /// FIFO of DECTCEM cursor-visibility deltas, one entry per submitted
    /// output chunk, popped by the matching ordered `outputApplied` event.
    private var pendingCursorVisibilityDeltas: [Bool?] = []
    #if DEBUG
    /// Last natural grid measured by a geometry pass (test seam).
    private var lastNaturalMeasurementForTesting: GhosttySurfaceMeasuredSize?
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
    /// Bounded retries for the viewport report round-trip. The report goes to
    /// the Mac, which echoes back the effective grid via `applyViewSize`. If the
    /// round-trip yields no effective grid (RPC timeout / lost reply), the
    /// render stays pinned to the prior `effectiveGrid` and looks frozen even
    /// though the main thread is fine. On a no-effective result we re-arm the
    /// report (display-link driven, no timers) up to `maxViewportReportRetries`
    /// so a transient drop self-heals; a confirmed result resets the count.
    private var viewportReportRetries = 0
    private static let maxViewportReportRetries = 3
    /// Frames of "no zoom in progress" required before the natural grid is
    /// reported to the Mac. Active zoom is already gated separately
    /// (`zoomSettleFrames != nil` holds the report during a pinch), so this is
    /// purely the post-settle latency for discrete resizes (keyboard show/hide,
    /// rotation, toolbar). The natural grid changes once per such event (not per
    /// animation frame), so a short settle still coalesces a burst without
    /// adding the old ~0.5s tail before the Mac reflows and re-sends. ~0.07s at
    /// 120Hz / 0.13s at 60Hz.
    private static let viewportReportSettleThreshold = 8
    /// Daemon-authoritative effective grid (min across attached devices). When
    /// set, the Ghostty surface is pinned to this cols×rows inside the
    /// container so every attached device renders at the same grid. When
    /// nil, the surface fills the container's natural capacity.
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

    #if DEBUG
    struct DebugGeometrySnapshot {
        let boundsSize: CGSize
        let renderRect: CGRect
        let screenScale: CGFloat
        let reportedSize: TerminalGridSize?
        let renderedSize: TerminalGridSize?
        let isLetterboxBorderVisible: Bool
        let letterboxBorderPathBounds: CGRect?
    }

    func debugGeometrySnapshotForTesting() -> DebugGeometrySnapshot {
        let renderedSize: TerminalGridSize? = lastNaturalMeasurementForTesting.map { measured in
            TerminalGridSize(
                columns: measured.columns,
                rows: measured.rows,
                pixelWidth: measured.pixelWidth,
                pixelHeight: measured.pixelHeight
            )
        }
        return DebugGeometrySnapshot(
            boundsSize: bounds.size,
            renderRect: lastRenderRect,
            screenScale: preferredScreenScale,
            reportedSize: lastReportedSize,
            renderedSize: renderedSize,
            isLetterboxBorderVisible: letterboxBorderLayer?.isHidden == false,
            letterboxBorderPathBounds: letterboxBorderLayer?.path?.boundingBoxOfPath
        )
    }

    func setKeyboardHeightForTesting(_ height: CGFloat) {
        keyboardHeight = max(0, height)
        syncSurfaceGeometry(shouldReassertNaturalSize: true)
    }
    #endif

    var currentGridSize: TerminalGridSize {
        lastReportedSize ?? TerminalGridSize(columns: 100, rows: 32, pixelWidth: 900, pixelHeight: 650)
    }

    /// Root-constructed accessory-bar configuration, forwarded to the input
    /// proxy's toolbar builder.
    private let accessoryConfiguration: TerminalAccessoryConfiguration

    private lazy var inputProxy: TerminalInputTextView = {
        let inputProxy = TerminalInputTextView(accessoryConfiguration: accessoryConfiguration)
        inputProxy.onText = { [weak self] text in
            guard let self else { return }
            self.resetCursorBlink()
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
            self.resetCursorBlink()
            // Send DEL (0x7F) directly to transport as raw byte.
            let data = Data([0x7F])
            TerminalInputDebugLog.log("surface.onBackspace data=\(TerminalInputDebugLog.dataSummary(data))")
            self.delegate?.ghosttySurfaceView(self, didProduceInput: data)
        }
        inputProxy.onEscapeSequence = { [weak self] data in
            guard let self else { return }
            self.resetCursorBlink()
            TerminalInputDebugLog.log("surface.onEscape data=\(TerminalInputDebugLog.dataSummary(data))")
            self.delegate?.ghosttySurfaceView(self, didProduceInput: data)
        }
        inputProxy.onZoom = { [weak self] direction in
            self?.performFontZoom(direction)
        }
        inputProxy.onHideKeyboard = { [weak self] in
            guard let self else { return }
            // Toggle: dismiss when the keyboard is up, bring it back when down.
            if self.inputProxy.isFirstResponder {
                self.inputProxy.resignFirstResponder()
            } else {
                self.focusInput()
            }
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

    public init(
        engine: GhosttyEngineService,
        delegate: GhosttySurfaceViewDelegate,
        accessoryConfiguration: TerminalAccessoryConfiguration,
        fontSize: Float32 = 10
    ) {
        self.engine = engine
        self.registry = engine.registry
        self.delegate = delegate
        self.accessoryConfiguration = accessoryConfiguration
        self.fontSize = fontSize
        self.liveFontSize = fontSize
        super.init(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        backgroundColor = .black
        isOpaque = true
        #if DEBUG
        // The surface is a container, not a leaf, so the docked toolbar's
        // buttons stay accessible. `debugAccessibilityProxy` carries the
        // `MobileTerminalSurface` identifier + rendered-text label instead.
        isAccessibilityElement = false
        #endif
        addSubview(snapshotFallbackView)
        addSubview(inputProxy)
        #if DEBUG
        addSubview(debugAccessibilityProxy)
        #endif
        installPersistentToolbar()
        initializeSurface()

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

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
            selector: #selector(handleKeyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
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
        guard session != nil, window != nil else { return }
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
        stopDisplayLink()
        guard let session else { return }
        session.setOcclusion(visible: false)  // occluded; drawFrame skips
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
        needsAnotherRender = false
        guard let session, window != nil else { return }
        session.setOcclusion(visible: true)
        setFocus(true)
        needsDraw = true
        startDisplayLink()
    }

    private var keyboardHeight: CGFloat = 0
    /// Height the persistent bottom toolbar reserves in the terminal grid. The
    /// toolbar is docked above the keyboard (when up) or the home indicator
    /// (when down) via `keyboardLayoutGuide`, so the grid must shrink by this
    /// much to keep the bottom TUI rows visible above it. 0 until the toolbar is
    /// installed (`installPersistentToolbar`), so the home-indicator reservation
    /// still lands even if the toolbar UI is absent.
    private var reservedToolbarHeight: CGFloat = 0
    /// Height of the docked accessory bar (the button row). Reserved in the grid
    /// geometry so the bottom TUI rows stay visible above it.
    private static let persistentToolbarHeight: CGFloat = 44
    /// The docked accessory bar. Positioned by `dockedToolbarFrame()` with the
    /// SAME bottom-occupancy math as the grid reservation, so its top is always
    /// flush with the grid bottom (no gap) and its bottom rests on the keyboard
    /// edge (up) or above the home indicator (down).
    private weak var dockedToolbar: UIView?
    public var autoFocusOnWindowAttach = true

    @objc private func handleKeyboardWillShow(_ notification: Notification) {
        guard let frameEnd = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let window else { return }
        let keyboardFrameInView = convert(frameEnd, from: window)
        let overlap = max(0, bounds.maxY - keyboardFrameInView.minY)
        guard overlap != keyboardHeight else { return }
        keyboardHeight = overlap
        inputProxy.setKeyboardShown(true)
        animateDockedToolbar(with: notification)
        setNeedsGeometrySync()
    }

    @objc private func handleKeyboardWillHide(_ notification: Notification) {
        guard keyboardHeight != 0 else { return }
        keyboardHeight = 0
        inputProxy.setKeyboardShown(false)
        animateDockedToolbar(with: notification)
        setNeedsGeometrySync()
        // No explicit scrollback request here: the grid grew, so the viewport
        // report resizes the Mac surface and the producer exports the taller
        // viewport (which reveals more history) on its own.
    }

    #if DEBUG
    /// Test seam: force a synthetic keyboard height so the keyboard-up layout
    /// (docked toolbar riding the keyboard edge, grid reserving toolbar +
    /// keyboard) can be screenshotted on the simulator, which refuses to render
    /// the software keyboard. Drives the exact same geometry path as a real
    /// keyboard. Used only by the terminal-layout preview harness.
    public func debugSetKeyboardHeightForLayoutPreview(_ height: CGFloat) {
        keyboardHeight = max(0, height)
        inputProxy.setKeyboardShown(height > 0)
        layoutDockedToolbar()
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
        reservedToolbarHeight = Self.persistentToolbarHeight
        layoutDockedToolbar()
    }

    /// Full-width bar whose bottom sits on the keyboard (when up) or the very
    /// bottom edge (when down). It intentionally does NOT reserve the bottom
    /// safe area: the toolbar IS the bottom chrome, so the home indicator simply
    /// overlays its lower edge (like a system tab bar) instead of leaving an
    /// empty strip below it. Mirrors the `bottomInset` math in
    /// `syncSurfaceGeometry` so the toolbar top equals the grid bottom exactly.
    private func dockedToolbarFrame() -> CGRect {
        let occupied = max(0, keyboardHeight)
        let height = Self.persistentToolbarHeight
        return CGRect(x: 0, y: bounds.height - height - occupied, width: bounds.width, height: height)
    }

    private func layoutDockedToolbar() {
        dockedToolbar?.frame = dockedToolbarFrame()
    }

    /// Animate the docked toolbar in lockstep with a keyboard show/hide so it
    /// rides the keyboard edge instead of jumping. There is no interactive
    /// (swipe-down) dismissal in this terminal, so a notification-driven animate
    /// is sufficient and avoids the `keyboardLayoutGuide` safe-area mismatch.
    private func animateDockedToolbar(with notification: Notification) {
        guard let dockedToolbar else { return }
        let target = dockedToolbarFrame()
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int)
            ?? Int(UIView.AnimationCurve.easeInOut.rawValue)
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: UIView.AnimationOptions(rawValue: UInt(curveRaw) << 16)
        ) {
            dockedToolbar.frame = target
        }
    }

    private var pinchAccumulatedScale: CGFloat = 1.0

    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began || gesture.state == .changed || gesture.state == .ended {
            MobileDebugLog.anchormux("scroll.pan state=\(gesture.state.rawValue) ty=\(Int(gesture.translation(in: self).y))")
        }
        // Forward scroll to the MAC's real surface instead of scrolling this
        // display-only mirror. The Mac owns scrollback (normal screen) and the
        // program owns alt-screen scroll (mouse-wheel to the PTY); a single
        // `ghostty_surface_mouse_scroll` on the real surface does the
        // mode-correct thing, and the render-grid (which exports the live
        // viewport, `vp_top`) mirrors the result back. Scrolling the local
        // mirror could never do either: it has no scrollback and no program.
        switch gesture.state {
        case .changed:
            let translation = gesture.translation(in: self)
            // Aim for ~1:1 natural scrolling. Measured: the Mac applies a ~3x
            // line multiplier to the wheel delta, so dividing the finger travel
            // by (cell height in points × 3) makes a swipe move the content
            // roughly its own distance. Falls back to a fixed divisor before the
            // first geometry pass measures the cell.
            let cellHeightPt = cellPixelSize.height / max(preferredScreenScale, 1)
            let divisor = cellHeightPt > 1 ? Double(cellHeightPt) * 3 : 42
            pendingScrollLines += Double(translation.y) / divisor
            pendingScrollCell = scrollCell(at: gesture.location(in: self))
            gesture.setTranslation(.zero, in: self)
        case .ended, .cancelled:
            flushPendingScrollIfNeeded()
        default:
            break
        }
    }

    /// Coalesced scroll forwarded to the Mac once per display-link frame.
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
        MobileDebugLog.anchormux("scroll.forward lines=\(String(format: "%.2f", lines)) cell=\(cell.col)x\(cell.row)")
        delegate?.ghosttySurfaceView(self, didScrollLines: lines, atCol: cell.col, row: cell.row)
    }

    /// A tap both raises the software keyboard (so the user can type) and
    /// forwards a left click at the tapped cell to the Mac. The Mac's libghostty
    /// self-gates: TUIs with mouse reporting get the click; a normal screen
    /// treats it as a harmless empty selection, so tapping a shell still just
    /// focuses input.
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let cell = scrollCell(at: gesture.location(in: self))
        delegate?.ghosttySurfaceView(self, didTapAtCol: cell.col, row: cell.row)
        focusInput()
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
        guard session != nil else { return false }

        pendingFontSize = target
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
        guard let target = pendingFontSize, let session else { return false }
        pendingFontSize = nil
        guard target != liveFontSize else { return false }
        liveFontSize = target
        MobileDebugLog.anchormux("zoom.apply \(target) eff=\(effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "nil")")
        // Absolute set: the prior `±1` binding action drove libghostty's own
        // font counter independently of our clamp, so a fast burst could push
        // it past `maximumSize` toward the 255pt ceiling and collapse the grid.
        // An absolute `set_font_size:<target>` keeps libghostty in lockstep
        // with `liveFontSize`, which we keep inside [minimumSize, maximumSize].
        session.submit(.bindingAction("set_font_size:\(target)"))
        // Render the new font (the grid reflows inside the current surface) but
        // do NOT resize the surface this frame. Resizing the render target on
        // every zoom step reallocates the IOSurface and stalls `render_now`'s
        // GPU frame wait (the wedge). Defer one geometry resync until zoom goes
        // quiet via the settle counter, re-armed on every apply.
        needsDraw = true
        zoomSettleFrames = Self.zoomSettleFrameThreshold
        return true
    }

    /// Set the live zoom to an absolute size (clamped to the font range),
    /// driving the same coalesced apply path as a pinch step. Used by the
    /// zoom-control overlay's reset / restore-built-in actions.
    private func applyAbsoluteFontSize(_ target: Float32) {
        guard session != nil else { return }
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
            self.applyAbsoluteFontSize(target)
            self.zoomOverlay?.updateZoom(points: target)
        }
        overlay.onSaveAsDefault = { [weak self] in
            guard let self else { return }
            self.zoomPreference.save(self.pendingFontSize ?? self.liveFontSize)
        }
        overlay.onRestoreBuiltIn = { [weak self] in
            guard let self else { return }
            self.zoomPreference.clear()
            self.applyAbsoluteFontSize(MobileTerminalFontPreference.defaultSize)
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
        let bottomReserve = reservedToolbarHeight + max(0, keyboardHeight)
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
        snapshotFallbackView.frame = bounds
        #if DEBUG
        debugAccessibilityProxy.frame = bounds
        #endif
        inputProxy.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        inputProxy.updateAccessoryLayoutInsets()
        layoutDockedToolbar()
        layoutZoomOverlay()
        MobileDebugLog.anchormux("surface.layout bounds=\(Int(bounds.width))x\(Int(bounds.height)) window=\(window != nil)")
        setNeedsGeometrySync()
        syncSurfaceVisibility()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        MobileDebugLog.anchormux("surface.didMoveToWindow window=\(window != nil)")
        syncSurfaceVisibility()
        if window != nil {
            setNeedsGeometrySync()
            setFocus(true)
            if autoFocusOnWindowAttach {
                focusInput()
            }
            startDisplayLink()
        } else {
            stopDisplayLink()
            setFocus(false)
        }
    }

    private var lastProcessOutputLogTime: CFTimeInterval = 0

    public func processOutput(_ data: Data) {
        guard let session else { return }
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
        // Track the host's cursor-visible mode (DECTCEM) straight from the VT
        // bytes the surface is about to apply, so the cursor overlay can match a
        // TUI that hides the cursor. nil = this delta carried no DECTCEM, so the
        // previous visibility stands. Queued FIFO; the matching ordered
        // `outputApplied` event pops it.
        pendingCursorVisibilityDeltas.append(Self.lastCursorVisibility(in: forwarded))

        // `ghostty_surface_process_output` BLOCKS on libghostty's internal
        // renderer/IO synchronization (a futex). Device crash logs show it
        // hanging the main thread (`Thread.Futex.Deadline.wait`) until the
        // scene-update watchdog (0x8BADF00D) kills the app. The session runs
        // it on its dedicated serial executor (order preserved) and the
        // `outputApplied` host event hops back here for the UI state.
        session.submit(.output(forwarded))
    }

    /// Applies one `outputApplied` host event on the main actor: the
    /// post-`process_output` UI work that used to live in the output queue's
    /// `DispatchQueue.main.async` completion.
    private func handleOutputApplied(accessibilityText: String?) {
        needsDraw = true
        let cursorVisibilityDelta = pendingCursorVisibilityDeltas.isEmpty
            ? nil
            : pendingCursorVisibilityDeltas.removeFirst()
        if let cursorVisibilityDelta, cursorVisibilityDelta != hostCursorVisible {
            hostCursorVisible = cursorVisibilityDelta
            updateCursorOverlay()
        }
        #if DEBUG
        lastOutputAppliedTime = CACurrentMediaTime()
        #endif
        if !surfaceHasReceivedOutput {
            surfaceHasReceivedOutput = true
            snapshotFallbackView.isHidden = true
            scrollInitialOutputToBottomIfNeeded()
        }
        let now = CACurrentMediaTime()
        if now - lastProcessOutputLogTime > 1.0 {
            lastProcessOutputLogTime = now
            if window != nil {
                logLayerTree(reason: "processOutput")
            }
        }
        #if DEBUG
        if let accessibilityText, !accessibilityText.isEmpty {
            debugAccessibilityProxy.accessibilityLabel = accessibilityText
            wantsTrailingAccessibilityTextRead = false
        } else {
            // This chunk's read was throttled (or came back empty); arm the
            // display-link-driven trailing read so the FINAL state of a burst
            // still lands on the label once output goes quiet. Without this a
            // quiescent stream (e.g. a TUI alt-screen replay that arrives as
            // one sub-500ms burst) leaves the label stale forever — the
            // XCUITest "Rows: [\"0:\"]" failure mode.
            wantsTrailingAccessibilityTextRead = true
        }
        onOutputProcessedForTesting?()
        #endif
    }

    #if DEBUG
    /// Trailing-edge accessibility read state; see ``handleOutputApplied``.
    private var wantsTrailingAccessibilityTextRead = false
    private var trailingAccessibilityTextReadInFlight = false
    /// Output must be quiet this long before the trailing read fires (just
    /// past the session's 500 ms in-burst throttle).
    private static let trailingAccessibilityTextQuietSeconds: CFTimeInterval = 0.6

    /// Fires at most one session-executor text read once output has been
    /// quiet, so the accessibility label converges on the final rendered
    /// state. Display-link driven (no timers); DEBUG/XCUITest-only.
    private func refreshTrailingAccessibilityTextIfNeeded(now: CFTimeInterval) {
        guard wantsTrailingAccessibilityTextRead,
              !trailingAccessibilityTextReadInFlight,
              now - lastOutputAppliedTime > Self.trailingAccessibilityTextQuietSeconds,
              let session else { return }
        wantsTrailingAccessibilityTextRead = false
        trailingAccessibilityTextReadInFlight = true
        Task { @MainActor [weak self] in
            let text = await session.longestReadableText()
            guard let self else { return }
            self.trailingAccessibilityTextReadInFlight = false
            if let text, !text.isEmpty {
                self.debugAccessibilityProxy.accessibilityLabel = text
            }
        }
    }
    #endif

    private func scrollInitialOutputToBottomIfNeeded() {
        guard shouldScrollInitialOutputToBottom, let session else { return }
        shouldScrollInitialOutputToBottom = false
        // `ghostty_surface_binding_action` takes the same internal surface lock
        // as `process_output`/`render_now`, so it must stay off main; the
        // session command stream also preserves ordering after any pending
        // `process_output`, exactly like the old serial-queue enqueue.
        session.submit(.bindingAction("scroll_to_bottom"))
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

    @objc
    func focusInput() {
        onFocusInputRequestedForTesting?()
        setNeedsGeometrySync()
        inputProxy.updateAccessoryLayoutInsets()
        inputProxy.becomeFirstResponder()
    }

    func simulateTextInputForTesting(_ text: String) {
        setFocus(true)
        sendText(text)
        engine?.tick()
    }

    func simulatePasteInputForTesting(_ text: String) {
        setFocus(true)
        sendPaste(text)
        engine?.tick()
    }

    func simulateInputProxyTextChangeForTesting(_ text: String, isComposing: Bool) {
        setFocus(true)
        inputProxy.simulateTextChangeForTesting(text, isComposing: isComposing)
        engine?.tick()
    }

    /// Reads the surface text for `scope` on the session's serial executor
    /// (never the main thread; see the session docs for the watchdog history).
    func renderedTextForTesting(scope: GhosttySurfaceTextScope = .viewport) async -> String? {
        await session?.readText(scope)
    }

    #if DEBUG
    /// The longest readable surface text across all scopes, read on the
    /// session executor. Async replacement for the old main-thread read.
    func renderedSurfaceTextForTesting() async -> String? {
        await session?.longestReadableText()
    }

    func accessibilityRenderedTextForTesting() -> String? {
        // The throttled session-side read feeds the proxy's label via
        // `outputApplied` events; this returns the last delivered value.
        debugAccessibilityProxy.accessibilityLabel
    }
    #endif

    func disposeSurface() {
        stopDisplayLink()
        guard let session else { return }
        if let surfaceIdentity {
            registry?.unregister(identity: surfaceIdentity)
        }
        self.session = nil
        surfaceIdentity = nil
        hostEventTask?.cancel()
        hostEventTask = nil
        // Drains queued commands on the session executor, then frees the
        // surface (the old GhosttySurfaceDisposer free-after-detach order).
        session.shutdown()
    }

    private var preferredScreenScale: CGFloat {
        if let screen = window?.windowScene?.screen {
            return screen.scale
        }

        let traitScale = traitCollection.displayScale
        return traitScale > 0 ? traitScale : 2
    }

    private func sendText(_ text: String) {
        guard let session else { return }
        let normalized = text.replacingOccurrences(of: "\n", with: "\r")
        guard !normalized.isEmpty else { return }
        session.submit(.textInput(normalized))
    }

    private func sendPaste(_ text: String) {
        guard let session else { return }
        guard !text.isEmpty else { return }
        session.submit(.pasteText(text))
    }

    private func initializeSurface() {
        guard let engine,
              let creation = engine.makeSurfaceSession(
                  hostView: self,
                  fontSize: fontSize,
                  scale: Double(preferredScreenScale)
              ) else { return }
        session = creation.session
        surfaceIdentity = creation.identity
        startHostEventTask(events: creation.events)
        registry?.setSnapshotContextProvider(identity: creation.identity) { [weak self] in
            guard let self, self.window != nil, !self.isHidden, self.alpha > 0.01 else { return nil }
            let grid = self.effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "?"
            return GhosttySurfaceSnapshotContext(gridDescription: grid, fontSize: Int(self.liveFontSize))
        }
        applyThemeColorsFromEngine()
        // Hide the snapshot fallback immediately. The Metal renderer
        // handles all rendering once the surface exists.
        snapshotFallbackView.isHidden = true
        surfaceHasReceivedOutput = true
        setNeedsGeometrySync()
        startDisplayLink()
    }

    /// The single ordered consumer of this surface's host events; every
    /// engine/session/callback result is applied here on the main actor.
    private func startHostEventTask(events: AsyncStream<GhosttySurfaceHostEvent>) {
        hostEventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                self.handleHostEvent(event)
            }
        }
    }

    private func handleHostEvent(_ event: GhosttySurfaceHostEvent) {
        switch event {
        case .outputApplied(let accessibilityText):
            handleOutputApplied(accessibilityText: accessibilityText)
        case .renderCompleted:
            renderInFlight = false
            #if DEBUG
            onRenderCompletedForTesting?()
            #endif
            if needsAnotherRender {
                needsAnotherRender = false
                requestRender()
            }
        case .geometryMeasured(let measurement):
            applyGeometryMeasurement(measurement)
        case .outboundBytes(let bytes):
            handleOutboundBytes(bytes)
        case .closeRequested(let processAlive):
            NotificationCenter.default.post(
                name: .ghosttySurfaceDidRequestClose,
                object: self,
                userInfo: ["process_alive": processAlive]
            )
        case .focusInputRequested:
            focusInput()
        case .titleChanged(let title):
            surfaceTitle = title
        case .bellRang:
            handleBell()
        }
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

    /// Reset cursor to visible and restart blink cycle (call on user input).
    private func resetCursorBlink() {
        guard session != nil else { return }
        cursorBlinkState.reset(now: CACurrentMediaTime())
        needsDraw = true
        updateCursorOverlay()
    }

    @objc func handleDisplayLinkFire() {
        guard session != nil else { return }
        #if DEBUG
        // Main-thread liveness heartbeat + presented-surface state. Time-gated,
        // no behavior change. The `contents`/size fields let an IDLE blank be
        // classified without a fresh output/geometry event: contents=false ⇒
        // the IOSurface lost its frame and nothing re-triggered a draw (redraw
        // bug); contents=true while the screen looks blank ⇒ the render-grid
        // content itself is empty (sync/producer). `sinceOutput` ties a blank
        // to a render-grid stream gap or rules it out. CALayer reads only — no
        // libghostty call, so no futex/main-thread-wedge risk.
        let nowHeartbeat = CACurrentMediaTime()
        if nowHeartbeat - lastHeartbeatTime >= 2.0 {
            lastHeartbeatTime = nowHeartbeat
            let renderLayer = (layer.sublayers ?? []).first(where: { isGhosttyRendererLayer($0) })
            let renderSize = renderLayer?.bounds.size ?? .zero
            let sinceOutputMs = lastOutputAppliedTime > 0
                ? Int((nowHeartbeat - lastOutputAppliedTime) * 1000)
                : -1
            MobileDebugLog.anchormux(
                "tick.alive win=\(window != nil) renderInFlight=\(renderInFlight) "
                + "needsDraw=\(needsDraw) contents=\(renderLayer?.contents != nil) "
                + "surf=\(Int(renderSize.width))x\(Int(renderSize.height)) "
                + "sinceOutput=\(sinceOutputMs)ms"
            )
        }
        refreshTrailingAccessibilityTextIfNeeded(now: nowHeartbeat)
        #endif
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
        let now = CACurrentMediaTime()
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
                    MobileDebugLog.anchormux("zoom.report grid=\(pending.columns)x\(pending.rows)")
                    delegate?.ghosttySurfaceView(self, didResize: pending)
                }
            }
        }

        // Flush coalesced scroll to the Mac at most once per frame.
        flushPendingScrollIfNeeded()

        // Fade the zoom HUD once interaction has been quiet. Uses real elapsed
        // time off the continuous display link (no timer / sleep).
        if zoomOverlayShown,
           CACurrentMediaTime() - zoomOverlayLastInteraction > Self.zoomOverlayVisibleDuration {
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
        // libghostty, leaving the serial command queue undrained. The acquire
        // is now bounded in libghostty (so a foreground stall self-heals as a
        // skipped frame the display link re-drives), but we still gate on
        // suspension; `resumeRendering` clears it on the next active transition.
        guard !renderingSuspended, let session else { return }
        // Coalesce: never let more than one render_now sit on the session's
        // serial executor. (Called on main from the display link; the
        // `renderCompleted` host event clears the flag.)
        if renderInFlight {
            needsAnotherRender = true
            return
        }
        renderInFlight = true
        session.submit(.render)
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
        guard let session,
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
        let imePoint = session.imePoint()

        let scale = max(preferredScreenScale, 1)
        overlay.contentsScale = scale
        let cellWidth = max(cellPixelSize.width / scale, 1)
        let cellHeight = max(CGFloat(imePoint.height), cellPixelSize.height / scale, 1)
        let cursorWidth = max(1.0 / scale, min(CGFloat(1.5), cellWidth))
        let cursorX = lastRenderRect.minX + CGFloat(imePoint.x) - (cellWidth / 2)
        let cursorY = lastRenderRect.minY + CGFloat(imePoint.y) - cellHeight
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

    private func applyThemeColorsFromEngine() {
        guard let engine else { return }
        if let color = engine.configColor(forKey: "background") {
            let bg = UIColor(
                red: CGFloat(color.red) / 255.0,
                green: CGFloat(color.green) / 255.0,
                blue: CGFloat(color.blue) / 255.0,
                alpha: 1.0
            )
            backgroundColor = bg
            snapshotFallbackView.backgroundColor = bg
            configBackgroundColor = bg
        }
        if let color = engine.configColor(forKey: "foreground") {
            snapshotFallbackView.textColor = UIColor(
                red: CGFloat(color.red) / 255.0,
                green: CGFloat(color.green) / 255.0,
                blue: CGFloat(color.blue) / 255.0,
                alpha: 1.0
            )
        }
        if let color = engine.configColor(forKey: "cursor-color") {
            configCursorColor = UIColor(
                red: CGFloat(color.red) / 255.0,
                green: CGFloat(color.green) / 255.0,
                blue: CGFloat(color.blue) / 255.0,
                alpha: 1.0
            )
        }
    }

    private func setFocus(_ focused: Bool) {
        session?.setFocus(focused)
    }

    private func syncSurfaceVisibility() {
        guard let session else { return }
        let visible = window != nil &&
            !isHidden &&
            alpha > 0.01 &&
            bounds.width > 0 &&
            bounds.height > 0
        MobileDebugLog.anchormux("surface.occlusion visible=\(visible) window=\(window != nil) hidden=\(isHidden) alpha=\(alpha)")
        session.setOcclusion(visible: visible)
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
        guard cols > 0, rows > 0 else { return }
        // A value came back from the Mac, so the round-trip recovered.
        viewportReportRetries = 0
        if effectiveGrid?.cols == cols && effectiveGrid?.rows == rows { return }
        MobileDebugLog.anchormux("zoom.applyViewSize eff=\(effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "nil")->\(cols)x\(rows)")
        effectiveGrid = (cols, rows)
        // Mark dirty instead of recomputing synchronously. This breaks the
        // feedback loop (didResize → updateTerminalViewport RPC → applyViewSize
        // → syncSurfaceGeometry → didResize …) that, under fast zoom, drove a
        // storm of set_size calls + viewport RPCs. Geometry now settles once
        // per frame, and reassert=false avoids re-reporting the unchanged
        // natural grid back through the round trip.
        setNeedsGeometrySync(reassertNaturalSize: false)
    }

    private func syncSurfaceGeometry(shouldReassertNaturalSize: Bool = true) {
        guard let session else { return }

        // Capture all main-actor inputs as values; the session performs every
        // libghostty WRITE (set_content_scale / set_size / fit) and its
        // readback on its dedicated serial executor. These calls push to
        // libghostty's renderer mailbox with a blocking `.forever` push; on
        // the main thread they hang it until the scene-update watchdog
        // (0x8BADF00D) kills the app. The main thread only applies the UIKit
        // result via the `geometryMeasured` host event.
        let scale = preferredScreenScale
        // Reserve the persistent toolbar plus the keyboard when it is up. The
        // toolbar sits flush at the bottom edge and is what keeps the bottom TUI
        // rows off the home indicator, so the grid does NOT also reserve the
        // bottom safe area (that left an empty strip below the toolbar). The
        // toolbar and keyboard never stack (the toolbar rides above the
        // keyboard), so the bottom occupancy is the toolbar plus the keyboard.
        let reservedBottom = reservedToolbarHeight + max(0, keyboardHeight)
        let bottomInset = min(reservedBottom, max(0, bounds.height - 1))
        let containerW = max(1, bounds.width)
        let containerH = max(1, bounds.height - bottomInset)
        let pushContentScale = abs(lastAppliedContentScale - scale) > 0.001
        if pushContentScale { lastAppliedContentScale = scale }

        let request = GhosttySurfaceGeometryRequest(
            containerWidth: Double(containerW),
            containerHeight: Double(containerH),
            scale: Double(scale),
            contentScaleToApply: pushContentScale ? Double(scale) : nil,
            pin: effectiveGrid.map { GhosttySurfaceGridPin(columns: $0.cols, rows: $0.rows) },
            reassertNaturalSize: shouldReassertNaturalSize
        )
        session.submit(.geometry(request))
    }

    /// Apply a session geometry pass on the main actor: only UIKit layer /
    /// cursor / border work plus the resize report. No blocking libghostty
    /// calls happen here.
    private func applyGeometryMeasurement(_ measurement: GhosttySurfaceGeometryMeasurement) {
        let scale = CGFloat(measurement.request.scale)
        let containerW = CGFloat(measurement.request.containerWidth)
        let containerH = CGFloat(measurement.request.containerHeight)
        let shouldReassertNaturalSize = measurement.request.reassertNaturalSize
        let result = (
            cellPixelSize: CGSize(width: measurement.cellPixelWidth, height: measurement.cellPixelHeight),
            naturalSize: TerminalGridSize(
                columns: measurement.natural.columns,
                rows: measurement.natural.rows,
                pixelWidth: measurement.natural.pixelWidth,
                pixelHeight: measurement.natural.pixelHeight
            ),
            pinnedSize: measurement.pinnedSize.map { CGSize(width: $0.width, height: $0.height) }
        )
        #if DEBUG
        lastNaturalMeasurementForTesting = measurement.natural
        #endif
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
        let renderRect = result.pinnedSize.map { CGRect(origin: .zero, size: $0) }
            ?? CGRect(origin: .zero, size: naturalRenderSize)
        lastRenderRect = renderRect
        MobileDebugLog.anchormux(
            "geom container=\(Int(containerW))x\(Int(containerH)) scale=\(scale) "
            + "cellPx=\(Int(result.cellPixelSize.width))x\(Int(result.cellPixelSize.height)) "
            + "natural=\(result.naturalSize.columns)x\(result.naturalSize.rows) "
            + "eff=\(effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "nil") "
            + "pinned=\(result.pinnedSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil") "
            + "renderRect=\(Int(renderRect.width))x\(Int(renderRect.height))"
        )
        syncRendererLayerFrame(scale: scale, renderRect: renderRect)
        updateLetterboxBorder(
            renderRect: renderRect,
            isLetterboxed: renderRect.width + 0.5 < containerW || renderRect.height + 0.5 < containerH
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
        let effectiveMatchesNatural = effectiveGrid.map { grid in
            grid.cols == naturalSize.columns && grid.rows == naturalSize.rows
        } ?? true
        let shouldReportNaturalSize = naturalSize != lastReportedSize ||
            (shouldReassertNaturalSize && !effectiveMatchesNatural)
        guard shouldReportNaturalSize, naturalSize.columns > 0, naturalSize.rows > 0 else { return }
        lastReportedSize = naturalSize
        // Debounce the actual report (a PTY resize on the Mac) until the grid
        // settles; the display link fires it once it stops changing.
        pendingViewportReport = naturalSize
        viewportReportSettleFrames = 0
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
        MobileDebugLog.anchormux("surface.layers reason=\(reason) host=\(hostSummary) children=[\(childSummaries)] fallbackHidden=\(snapshotFallbackView.isHidden) fallbackChars=\(snapshotFallbackView.text.count)")
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
        // Once the Metal renderer is active (the surface exists and has
        // received output), keep the fallback hidden so the IOSurfaceLayer is
        // visible. With session-owned text reads there is no synchronous
        // main-thread snapshot source anymore; the fallback only ever shows
        // when surface creation failed, where it stays empty.
        if surfaceHasReceivedOutput {
            snapshotFallbackView.isHidden = true
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
        return true
    }
}

extension Notification.Name {
    static let ghosttySurfaceDidRequestClose = Notification.Name("ghosttySurfaceDidRequestClose")
    static let ghosttySurfaceDidRingBell = Notification.Name("ghosttySurfaceDidRingBell")
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

// MARK: - Arrow Nub (draggable directional pad)

final class TerminalArrowNubView: UIView {
    var onArrowKey: ((Data) -> Void)?

    private let nubSize: CGFloat = 34
    private let deadZone: CGFloat = 8
    private let repeatInterval: Duration = .milliseconds(80)
    private let innerDot = UIView()
    private var dragOrigin: CGPoint = .zero
    /// Drives the immediate + interval arrow repeats off an injected `Clock`
    /// (replacing the run-loop `Timer`); cancellation is wired to the gesture.
    private let arrowRepeatService = TerminalArrowRepeatService()
    /// The in-flight repeat stream consumer. Cancelled on direction change /
    /// gesture end, which terminates the service stream's cadence.
    private var repeatTask: Task<Void, Never>?
    private var lastDirection: Direction?
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

    private enum Direction {
        case up, down, left, right
        var escapeSequence: Data {
            switch self {
            case .up:    return Data([0x1B, 0x5B, 0x41])
            case .down:  return Data([0x1B, 0x5B, 0x42])
            case .right: return Data([0x1B, 0x5B, 0x43])
            case .left:  return Data([0x1B, 0x5B, 0x44])
            }
        }

        var repeatDirection: TerminalArrowRepeatService.Direction {
            switch self {
            case .up:    return .upArrow
            case .down:  return .downArrow
            case .right: return .rightArrow
            case .left:  return .leftArrow
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.25, alpha: 0.85)
        layer.cornerRadius = nubSize / 2

        innerDot.backgroundColor = UIColor(white: 0.85, alpha: 1)
        innerDot.layer.cornerRadius = 6
        innerDot.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        innerDot.layer.shadowColor = UIColor.white.cgColor
        innerDot.layer.shadowOpacity = 0.3
        innerDot.layer.shadowRadius = 3
        innerDot.layer.shadowOffset = .zero
        addSubview(innerDot)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        feedbackGenerator.prepare()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if repeatTask == nil {
            innerDot.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: nubSize, height: nubSize)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            dragOrigin = innerDot.center
            feedbackGenerator.prepare()
        case .changed:
            let maxOffset: CGFloat = nubSize / 2 - 8
            let clampedX = max(-maxOffset, min(maxOffset, translation.x))
            let clampedY = max(-maxOffset, min(maxOffset, translation.y))
            innerDot.center = CGPoint(x: dragOrigin.x + clampedX, y: dragOrigin.y + clampedY)

            let direction = directionFrom(dx: translation.x, dy: translation.y)
            if direction != lastDirection {
                lastDirection = direction
                stopRepeat()
                if let direction {
                    startRepeat(direction)
                }
            }
        case .ended, .cancelled:
            stopRepeat()
            lastDirection = nil
            UIView.animate(withDuration: 0.15) {
                self.innerDot.center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
            }
        default:
            break
        }
    }

    private func directionFrom(dx: CGFloat, dy: CGFloat) -> Direction? {
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > deadZone else { return nil }
        if abs(dx) > abs(dy) {
            return dx > 0 ? .right : .left
        } else {
            return dy > 0 ? .down : .up
        }
    }

    /// Consume the service's repeat stream for `direction`: it emits the first
    /// arrow immediately and one per interval. Each emission fires haptics and
    /// forwards the bytes on the main actor. Cancelled by ``stopRepeat()``.
    private func startRepeat(_ direction: Direction) {
        let stream = arrowRepeatService.repeats(
            of: direction.repeatDirection,
            every: repeatInterval,
            clock: ContinuousClock()
        )
        repeatTask = Task { @MainActor [weak self] in
            for await bytes in stream {
                guard let self else { return }
                self.feedbackGenerator.impactOccurred()
                self.onArrowKey?(bytes)
            }
        }
    }

    private func stopRepeat() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

#endif
