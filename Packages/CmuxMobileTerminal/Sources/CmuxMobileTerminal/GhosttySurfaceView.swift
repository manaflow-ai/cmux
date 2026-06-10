#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileTerminalKit
import GhosttyKit
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

public final class GhosttySurfaceView: UIView, TerminalSurfaceHosting {
    /// The surface whose hidden text input is currently first responder, if any.
    ///
    /// Tracked statically so chrome (SwiftUI overlays presented over the
    /// terminal) can dismiss the live keyboard via ``resignActiveInput()``
    /// without holding a reference to the specific surface.
    static weak var activeInputSurface: GhosttySurfaceView?
    weak var runtime: GhosttyRuntime?
    weak var delegate: GhosttySurfaceViewDelegate?
    let fontSize: Float32
    /// Surface-owned live font size (points). Zoom mutates this; it is the
    /// source of truth for the current size, so the size accumulates correctly
    /// across taps even though the actual libghostty apply is coalesced.
    var liveFontSize: Float32
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
    var zoomSettleFrames: Int?
    static let zoomSettleFrameThreshold = 6
    /// The transient zoom-control HUD (reset/save/restore-built-in), created
    /// lazily on the first zoom. Centered over the surface; auto-fades.
    var zoomOverlay: MobileTerminalZoomControlOverlay?
    /// Whether the zoom HUD is currently presented (alpha animating toward 1).
    var zoomOverlayShown = false
    /// Media time of the last zoom interaction (pinch step, zoom button, or HUD
    /// tap). The display link fades the HUD once this is older than
    /// `zoomOverlayVisibleDuration`. Time-based off the per-frame callback, not a
    /// timer/`Task.sleep`, so it honors the no-sleep rule and tracks real
    /// elapsed time regardless of frame rate.
    var zoomOverlayLastInteraction: CFTimeInterval = 0
    static let zoomOverlayVisibleDuration: CFTimeInterval = 2.5
    /// Persisted user "default zoom" backing the zoom-control overlay's
    /// reset/save/restore actions. Owned by the surface (constructed at init)
    /// rather than reached through a singleton, so it is injectable in tests.
    let zoomPreference = MobileTerminalZoomPreference()
    let bridge = GhosttySurfaceBridge()
    let prefersSnapshotFallbackRendering = false
    var onFocusInputRequestedForTesting: (() -> Void)?
    var surfaceTitle: String?
    var displayLink: CADisplayLink?
    var cursorBlinkState = TerminalCursorBlinkState()
    var cursorOverlayLayer: CALayer?
    /// Whether the host terminal currently wants the cursor shown (DECTCEM).
    /// TUIs that hide the cursor (vim, fzf, htop, less, …) emit `ESC [ ? 25 l`;
    /// the render-grid producer forwards that in the VT-patch bytes, so we track
    /// the last applied state from the byte stream and hide the overlay to
    /// match. Defaults to visible (a normal shell shows its cursor).
    var hostCursorVisible: Bool = true
    var needsDraw: Bool = false
    /// Countdown of extra draw requests after a geometry change, so the
    /// renderer (which presents a frame behind) produces a frame at the final
    /// settled layer size rather than leaving a stale mid-animation surface.
    /// Bounded to avoid a perpetual main-queue present flood.
    var pendingRenderFrames: Int = 0
    /// At most one `render_now` is in flight on `outputQueue` at a time. The
    /// display link can fire at 120Hz and previously enqueued a render every
    /// frame with no guard, so during a continuous pinch renders piled up
    /// faster than the serial queue drained them. Each op stayed fast, but the
    /// DISPLAYED frame fell seconds behind the live font and only caught up
    /// when zoom stopped and the backlog drained — the "frozen, no updates"
    /// symptom. Coalescing caps the backlog: while a render is in flight, mark
    /// `needsAnotherRender` and re-enqueue exactly one when it completes.
    var renderInFlight: Bool = false
    var needsAnotherRender: Bool = false
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
    var renderingSuspended: Bool = false
    #if DEBUG
    /// Last time the display-link heartbeat logged (DEBUG diagnostic). The
    /// per-frame callback runs on the main thread, so a steady heartbeat proves
    /// main is alive; if it stops while the screen looks frozen, the main
    /// thread wedged (vs. an idle terminal or a stuck letterbox pin, where the
    /// heartbeat keeps ticking). Distinguishes the three on the next dogfood.
    var lastHeartbeatTime: CFTimeInterval = 0
    /// Time of the most recent applied render-grid output, for the heartbeat's
    /// `sinceOutput` field (ties an idle blank to a stream gap).
    var lastOutputAppliedTime: CFTimeInterval = 0
    #endif
    /// Set by any geometry trigger (resize/zoom/keyboard/effective-grid pin);
    /// the display link applies geometry at most once per frame. Coalescing
    /// prevents the fast-zoom geometry storm that thrashed the grid (jumbled
    /// rendering) and saturated the renderer.
    var needsGeometrySync: Bool = false
    var pendingGeometryReassert: Bool = false
    /// Last content scale pushed to libghostty; used to skip redundant
    /// per-frame `set_content_scale` pushes (the screen scale is constant).
    var lastAppliedContentScale: CGFloat = 0
    var surfaceHasReceivedOutput: Bool = false
    var shouldScrollInitialOutputToBottom = true
    /// Serial background queue for `ghostty_surface_process_output`, which
    /// blocks on libghostty's internal renderer/IO futex. Running it on the
    /// main thread hangs the app until the scene-update watchdog kills it.
    static let outputQueue = DispatchQueue(
        label: "dev.cmux.GhosttySurfaceView.output",
        qos: .userInitiated
    )
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
    lazy var debugAccessibilityProxy: UIView = {
        let proxy = UIView()
        proxy.backgroundColor = .clear
        proxy.isUserInteractionEnabled = false
        proxy.isAccessibilityElement = true
        proxy.accessibilityIdentifier = "MobileTerminalSurface"
        return proxy
    }()
    #endif
    let snapshotFallbackView: UITextView = {
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
    var lastReportedSize: TerminalGridSize?
    /// Latest natural grid awaiting a debounced report to the Mac. The display
    /// link sends it only after the grid has held steady for
    /// `viewportReportSettleThreshold` frames. Reporting every intermediate
    /// size during the attach / keyboard / zoom settle resized the Mac PTY
    /// repeatedly, so the shell redrew its prompt on each SIGWINCH and the
    /// initial scrollback filled with the prompt duplicated at every width.
    var pendingViewportReport: TerminalGridSize?
    var viewportReportSettleFrames = 0
    /// Bounded retries for the viewport report round-trip. The report goes to
    /// the Mac, which echoes back the effective grid via `applyViewSize`. If the
    /// round-trip yields no effective grid (RPC timeout / lost reply), the
    /// render stays pinned to the prior `effectiveGrid` and looks frozen even
    /// though the main thread is fine. On a no-effective result we re-arm the
    /// report (display-link driven, no timers) up to `maxViewportReportRetries`
    /// so a transient drop self-heals; a confirmed result resets the count.
    var viewportReportRetries = 0
    static let maxViewportReportRetries = 3
    /// Frames of "no zoom in progress" required before the natural grid is
    /// reported to the Mac. Active zoom is already gated separately
    /// (`zoomSettleFrames != nil` holds the report during a pinch), so this is
    /// purely the post-settle latency for discrete resizes (keyboard show/hide,
    /// rotation, toolbar). The natural grid changes once per such event (not per
    /// animation frame), so a short settle still coalesces a burst without
    /// adding the old ~0.5s tail before the Mac reflows and re-sends. ~0.07s at
    /// 120Hz / 0.13s at 60Hz.
    static let viewportReportSettleThreshold = 8
    var lastSnapshotFallbackHTML: String?
    /// Daemon-authoritative effective grid (min across attached devices). When
    /// set, the Ghostty surface is pinned to this cols×rows inside the
    /// container so every attached device renders at the same grid. When
    /// nil, the surface fills the container's natural capacity.
    var effectiveGrid: (cols: Int, rows: Int)?
    /// Cached cell metrics derived from the most recent
    /// `ghostty_surface_size` measurement. Used to translate an effective
    /// cols×rows pin into a pixel box without re-round-tripping through
    /// Ghostty. Zero until the first layout has measured.
    var cellPixelSize: CGSize = .zero
    /// 1 px separator stroke drawn around the pinned surface rect when the
    /// container is larger than the render target (i.e., this device is
    /// not the smallest). Added lazily on first letterbox.
    var letterboxBorderLayer: CAShapeLayer?
    /// Last render rect used for the Ghostty surface inside the host view's
    /// coordinate space. Kept so the border layer can match it without a
    /// second set_size round-trip.
    var lastRenderRect: CGRect = .zero

    lazy var inputProxy: TerminalInputTextView = {
        let inputProxy = TerminalInputTextView()
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
        inputProxy.onPasteImage = { [weak self] data, format in
            guard let self else { return }
            TerminalInputDebugLog.log("surface.onPasteImage bytes=\(data.count) format=\(format)")
            self.delegate?.ghosttySurfaceView(self, didPasteImage: data, format: format)
        }
        inputProxy.onZoom = { [weak self] direction in
            self?.performFontZoom(direction)
        }
        inputProxy.onHideKeyboard = { [weak self] in
            guard let self else { return }
            // Toggle: dismiss when the keyboard is up, bring it back when down.
            if self.inputProxy.isFirstResponder {
                self.resignInput()
            } else {
                self.focusInput()
            }
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
        super.init(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        bridge.attach(to: self)
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

    var keyboardHeight: CGFloat = 0
    /// Height the persistent bottom toolbar reserves in the terminal grid. The
    /// toolbar is docked above the keyboard (when up) or the home indicator
    /// (when down) via `keyboardLayoutGuide`, so the grid must shrink by this
    /// much to keep the bottom TUI rows visible above it. 0 until the toolbar is
    /// installed (`installPersistentToolbar`), so the home-indicator reservation
    /// still lands even if the toolbar UI is absent.
    var reservedToolbarHeight: CGFloat = 0
    /// Height of the docked accessory bar (the button row). Reserved in the grid
    /// geometry so the bottom TUI rows stay visible above it.
    static let persistentToolbarHeight: CGFloat = 44
    /// The docked accessory bar. Positioned by `dockedToolbarFrame()` with the
    /// SAME bottom-occupancy math as the grid reservation, so its top is always
    /// flush with the grid bottom (no gap) and its bottom rests on the keyboard
    /// edge (up) or above the home indicator (down).
    weak var dockedToolbar: UIView?
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

    var pinchAccumulatedScale: CGFloat = 1.0

    /// Coalesced scroll forwarded to the Mac once per display-link frame.
    var pendingScrollLines: Double = 0
    var pendingScrollCell: (col: Int, row: Int) = (0, 0)

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
        guard let surface, !isDismantled else { return }
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
        // previous visibility stands.
        let cursorVisibilityDelta = Self.lastCursorVisibility(in: forwarded)

        // `ghostty_surface_process_output` BLOCKS on libghostty's internal
        // renderer/IO synchronization (a futex). Device crash logs show it
        // hanging the main thread (`Thread.Futex.Deadline.wait`) until the
        // scene-update watchdog (0x8BADF00D) kills the app. It must run off
        // the main thread. Feed it on a serial background queue (order
        // preserved) and hop back to main only for the Swift-side UI state.
        Self.outputQueue.async { [weak self] in
            forwarded.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                let pointer = baseAddress.assumingMemoryBound(to: CChar.self)
                ghostty_surface_process_output(surface, pointer, UInt(buffer.count))
            }
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
            if a11yNow - Self.lastAccessibilityTextTime > 0.5 {
                Self.lastAccessibilityTextTime = a11yNow
                accessibilityText = Self.accessibilitySurfaceText(surface)
            }
            #endif
            DispatchQueue.main.async {
                guard let self, !self.isDismantled else { return }
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
            }
        }
    }

    private(set) var configBackgroundColor: UIColor?
    private(set) var configCursorColor: UIColor?

    func applyBackgroundColorFromConfig(_ config: ghostty_config_t) {
        var bgColor = ghostty_config_color_s()
        let bgKey = "background"
        if ghostty_config_get(config, &bgColor, bgKey, UInt(bgKey.lengthOfBytes(using: .utf8))) {
            let bg = UIColor(red: CGFloat(bgColor.r) / 255.0, green: CGFloat(bgColor.g) / 255.0, blue: CGFloat(bgColor.b) / 255.0, alpha: 1.0)
            backgroundColor = bg
            snapshotFallbackView.backgroundColor = bg
            configBackgroundColor = bg
            #if DEBUG
            log.debug("applyBg: config r=\(bgColor.r, privacy: .public) g=\(bgColor.g, privacy: .public) b=\(bgColor.b, privacy: .public) -> UIColor(\(bg.debugDescription, privacy: .public)), hardcoded Monokai=#272822 r=39 g=40 b=34")
            #endif
        } else {
            #if DEBUG
            log.debug("applyBg: ghostty_config_get returned false, no bg color from config")
            #endif
        }
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

/// One surface's request for the bounded visible-terminal snapshot.
///
/// The `ghostty_surface_t` is a C pointer that the snapshot only dereferences on
/// `GhosttySurfaceView.outputQueue` (the queue that owns `process_output`) and
/// never mutates, so carrying it across the queue hop is safe — hence
/// `@unchecked Sendable`.
struct VisibleSnapshotRequest: @unchecked Sendable {
    let grid: String
    let font: Int
    let surface: ghostty_surface_t
}

/// Carrier for the snapshot text produced off `GhosttySurfaceView.outputQueue`.
///
/// `sections` is written exactly once on that queue before its semaphore is
/// signaled and read by the caller only after the matching wait, so the two
/// accesses never overlap — hence `@unchecked Sendable`. On the timeout path the
/// caller never reads it, leaving the queue task the sole accessor.
final class VisibleSnapshotHolder: @unchecked Sendable {
    var sections: [String] = []
}

final class WeakGhosttySurfaceViewBox {
    weak var value: GhosttySurfaceView?

    init(_ value: GhosttySurfaceView) {
        self.value = value
    }
}

extension GhosttySurfaceView {
    @MainActor
    static var registeredSurfaceViews: [UInt: WeakGhosttySurfaceViewBox] = [:]

    @MainActor
    static func register(surface: ghostty_surface_t, for view: GhosttySurfaceView) {
        registeredSurfaceViews[surfaceIdentifier(for: surface)] = WeakGhosttySurfaceViewBox(view)
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
    }

    @MainActor
    static func unregister(surface: ghostty_surface_t) {
        registeredSurfaceViews.removeValue(forKey: surfaceIdentifier(for: surface))
    }

    @MainActor
    static func view(for surface: ghostty_surface_t) -> GhosttySurfaceView? {
        let identifier = surfaceIdentifier(for: surface)
        guard let view = registeredSurfaceViews[identifier]?.value else {
            registeredSurfaceViews.removeValue(forKey: identifier)
            return nil
        }
        return view
    }

    static func surfaceIdentifier(for surface: ghostty_surface_t) -> UInt {
        UInt(bitPattern: UnsafeRawPointer(surface))
    }
}

class DisplayLinkProxy {
    private weak var target: GhosttySurfaceView?

    init(target: GhosttySurfaceView) {
        self.target = target
    }

    @objc func handleDisplayLink() {
        target?.handleDisplayLinkFire()
    }
}

#endif
