public import AppKit
import CmuxNextCompat
import CmuxNextRemoteLayer
import QuartzCore

/// The one view a hosted Chromium page shows in, whichever process runs its
/// browser (plans/cmux-next/chrome-parity/p01-process.md, task 040).
///
/// Pixels: a `CALayerHost` on the page's Core Animation context id (the
/// CONTEXT frame of the Chromium host app, or fork API 26's
/// `cmux_shim_browser_set_layer_hosting` in process), so the page moves,
/// clips, hides and shows in the same Core Animation transaction as the panes
/// around it, with no WindowServer round trip for its pixels. A context id is
/// a WindowServer name, not a pointer: the same view shows a page whose
/// browser runs in another process. Chromium shows its GPU process's output
/// the same way (`ui/accelerated_widget_mac/display_ca_layer_tree.mm`).
///
/// Views: this view is layer-backed. The pixels live in ``surface``, a
/// layer-hosting subview with no subviews of its own; the crash overlay is a
/// sibling above it, so AppKit orders their layers as it orders the views.
///
/// Around the pixels: the page's background fill (shown wherever the page's
/// own pixels are not), a crash overlay slot over the page (host mode), and the
/// geometry the page's owner needs, reported only when the presented rect
/// changed (PATTERNS P8).
///
/// Input (``InputTarget``): with ``InputTarget/view`` this view is the page's
/// input target and first responder (host mode: mouse, scroll, keys and Edit
/// menu actions become wire frames for ``sink``, one per event, in the
/// event's own turn: no display-tick alignment here, the renderer aligns
/// input to its frames, as Chrome's browser process forwards input at once;
/// keys in ChromiumHostPageView+Keys.swift). With an owner that delivers the
/// host's input acks (``pacesInput``, ``inputAcked(_:)``; the input ring's
/// ``ChromiumHostInputRoute``), a move or wheel tick still leaves at once when
/// none of its kind is in flight, and later ones wait coalesced for the ack
/// (``ChromiumHostInputPacer``, task p01-process-042); keys and clicks never
/// wait, and what waited leaves ahead of them. With
/// ``InputTarget/pageWindow`` the fork's transparent page window above takes
/// every event (in-process layer hosting), and this view takes none.
public final class ChromiumHostPageView: NSView {
    /// Where the page's input goes.
    enum InputTarget: Equatable, Sendable {
        /// This view: it is hit-testable and becomes first responder (host mode).
        case view
        /// The page window above it (in-process layer hosting, fork API 26 and 27).
        case pageWindow
    }

    let inputTarget: InputTarget
    /// Names this view on the Chromium Host wire for a parent NSView* argument (host mode); 0 in process.
    var wireToken: UInt64 = 0
    /// The view's size or screen place changed (only when the rect differs from the last one reported).
    var onGeometry: ((ChromiumHostGeometry) -> Void)? {
        didSet { observeWindow() }
    }
    /// The view left its window (its pane closed, or it moved out of every window).
    var onLeftWindow: (() -> Void)?
    /// The view entered a window (true) or left its window (false): a hosted page is live only
    /// while its view is in one.
    var onWindowChange: ((Bool) -> Void)?
    /// The view became (`true`) or stopped being its window's first responder: in host mode the
    /// page's focus follows it (``CEFTab/applyFocus(_:browser:)``), as Chrome's page focus follows
    /// `RenderWidgetHostViewCocoa`'s (`OnFirstResponderChanged`,
    /// content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm).
    var onFocusChange: ((Bool) -> Void)?
    /// The shown context, 0 while none.
    var contextID: UInt32 { surface.contextID }
    /// The page's background, shown wherever the page's own pixels are not
    /// (no context yet, a host starting or restarting). Nil is see-through, as
    /// the in-process page window needs. Chromium fills its page view the same
    /// way (`RenderWidgetHostNSViewBridge::SetBackgroundColor`,
    /// `content/app_shim_remote_cocoa/render_widget_host_ns_view_bridge.mm`).
    var backgroundFill: CGColor? {
        get { surface.fill }
        set { surface.fill = newValue }
    }
    /// The view over the page that fills it (the crash page, p01-process-082); nil shows the page.
    private(set) var crashOverlay: NSView?
    /// The page's last picture while no host shows it; only ``showStandIn(_:)`` and ``removeStandIn()`` set it.
    var standIn: NSView?
    /// The layer-hosting view that shows the context, under every other subview.
    let surface: Surface
    /// The key-downs sent to the page that it may still report unhandled
    /// (``takeUnhandledKey(seq:browser:)``, ChromiumHostPageView+Keys.swift).
    var keyDowns = ChromiumHostKeyDowns()
    /// Whether the host this view's frames go to sends each key with `SendHostKeyEvent`, so a chord
    /// the page leaves unhandled comes back as KEY_UNHANDLED. Off, this view takes no chord from the
    /// main menu and the KeyRouter runs its actions before the page. The input route turns it on
    /// when it attaches a host whose key applier does that (tasks 041 and 042).
    var hostReportsUnhandledKeys = false
    /// Where a key the page left unhandled goes when no cmux action was held for it: the main
    /// menu, as Chrome re-dispatches such a key (`ui/base/cocoa/command_dispatcher.mm`,
    /// `-redispatchKeyEvent:`). Tests pass a recorder.
    var redispatchTarget: @MainActor (NSEvent) -> Bool = { NSApp.mainMenu?.performKeyEquivalent(with: $0) ?? false }
    /// True while ``redispatch(_:)`` runs: the page view does not take the key back.
    var isRedispatching = false

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Where frames for the host go (``InputTarget/view`` only), synchronously
    /// from the event handler: a sink must write or queue, never wait. Returns where the
    /// input writer put the frame (its browser and input seq), or nil when it stamped none.
    var sink: ((ChromiumHostFrame) -> ChromiumHostInputReceipt?)?
    /// Moves and wheel ticks wait for the host's ack of the one in flight; set
    /// by an owner that calls ``inputAcked(_:)`` (``ChromiumHostInputRoute``:
    /// the input ring's host acks each at dispatch). Off, every frame goes to
    /// ``sink`` at once. Turning it on or off forgets what was in flight.
    var pacesInput = false {
        didSet { inputPacer = pacesInput ? ChromiumHostInputPacer() : nil }
    }
    /// The pacing state while ``pacesInput``.
    private(set) var inputPacer: ChromiumHostInputPacer?
    private var tracking: NSTrackingArea?
    #endif

    private var lastGeometry: ChromiumHostGeometry?
    /// What moves the page on screen without changing this view's frame: the
    /// window's page update request (`BrowserPageUpdates`). The window's
    /// layout owner (`WindowOverlayLayer`) sends it once per change after
    /// panes, dividers or the sidebar moved and after the window moved,
    /// resized or changed screen; the in-process `CEFHostView` re-places its
    /// page on the same request.
    private var pageUpdates: MainActorObservation?
    /// Where the window's page update requests arrive.
    private let pageUpdateCenter: NotificationCenter

    /// - Parameters:
    ///   - inputTarget: who takes the page's input.
    ///   - makeLayerHost: the layer that shows a context id; a `CALayerHost` by
    ///     default (tests pass one that fails, or a plain layer).
    ///   - pageUpdateCenter: where the window's page update requests arrive;
    ///     `.default` in the app, a private center in tests.
    init(frame: NSRect, inputTarget: InputTarget,
         makeLayerHost: @escaping (UInt32) -> CALayer? = { ChromiumHostPageView.layerHost(contextID: $0) },
         pageUpdateCenter: NotificationCenter = .default) {
        self.inputTarget = inputTarget
        self.pageUpdateCenter = pageUpdateCenter
        surface = Surface(frame: NSRect(origin: .zero, size: frame.size), makeLayerHost: makeLayerHost)
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        addSubview(surface)
    }

    /// A host-mode page view: the page's input target.
    public override convenience init(frame: NSRect) {
        self.init(frame: frame, inputTarget: .view)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Unflipped: the page's root layer has its origin at the bottom left.
    public override var isFlipped: Bool { false }
    public override var acceptsFirstResponder: Bool { inputTarget == .view }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { inputTarget == .view }
    public override func isAccessibilityElement() -> Bool { false }

    public override func becomeFirstResponder() -> Bool {
        firstResponderChanged(true)
        return true
    }

    public override func resignFirstResponder() -> Bool {
        firstResponderChanged(false)
        return true
    }

    private func firstResponderChanged(_ focused: Bool) {
        onFocusChange?(focused)
        #if DEBUG || CMUX_BENCH_HOOKS
        sendInput(ChromiumHostFrame(.focus, v: [focused ? 1 : 0]))
        #endif
    }

    /// With ``InputTarget/pageWindow`` nothing here takes the mouse: the
    /// WindowServer gives every click in the page's rect to the page window above.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        inputTarget == .view ? super.hitTest(point) : nil
    }

    /// Shows `overlay` over the page, filling it; nil removes it. Host mode
    /// only: with ``InputTarget/pageWindow`` it returns false and shows
    /// nothing, because the fork's page window above the pane would take every
    /// click meant for the overlay.
    @discardableResult
    func setCrashOverlay(_ overlay: NSView?) -> Bool {
        guard overlay !== crashOverlay else { return true }
        guard overlay == nil || inputTarget == .view else { return false }
        crashOverlay?.removeFromSuperview()
        crashOverlay = overlay
        guard let overlay else { return true }
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay, positioned: .above, relativeTo: standIn ?? surface)
        return true
    }

    /// Shows context `id` (0 shows nothing: the page went away, or its host
    /// ended or restarts). False when `id` is not 0 and nothing can show it (no
    /// `CALayerHost`): an in-process caller gives the page its own window back
    /// instead of leaving it blank.
    @discardableResult
    func show(contextID id: UInt32) -> Bool {
        surface.show(contextID: id)
    }

    /// `CALayerHost` is QuartzCore SPI, the class Chromium itself uses to
    /// show its GPU process's output (`ui::DisplayCALayerTree`).
    nonisolated static func layerHost(contextID: UInt32) -> CALayer? {
        let layerHost = CALayerHost()
        layerHost.contextId = contextID
        return layerHost
    }

    /// `debug.cef` `tracker.hosted_pages` counts the hosted views in a
    /// window, so a view released with its pane (DevTools closed, a pane
    /// closed) never stays counted.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if window == nil, newWindow != nil {
            CEFHostView.trackerStats.hostedPages += 1
        } else if window != nil, newWindow == nil {
            CEFHostView.trackerStats.hostedPages -= 1
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
        onWindowChange?(window != nil)
        if window == nil {
            lastGeometry = nil
            keyDowns.removeAll()
            onLeftWindow?()
        } else {
            presentedRectDidChange()
        }
    }

    // MARK: Geometry

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        presentedRectDidChange()
    }

    public override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        presentedRectDidChange()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        presentedRectDidChange()
    }

    /// Reports the page's screen rect when it differs from the last one
    /// reported; an unchanged rect costs one comparison.
    private func presentedRectDidChange() {
        guard let onGeometry, let window, bounds.width >= 1, bounds.height >= 1 else { return }
        let screen = window.convertToScreen(convert(bounds, to: nil))
        let geometry = ChromiumHostGeometry(screenRect: screen, scale: window.backingScaleFactor)
        guard geometry != lastGeometry else { return }
        lastGeometry = geometry
        onGeometry(geometry)
    }

    /// Follows the window's page update request only while someone takes the geometry.
    private func observeWindow() {
        guard onGeometry != nil, let window else {
            pageUpdates = nil
            return
        }
        pageUpdates = BrowserPageUpdates.observe(of: window, center: pageUpdateCenter) { [weak self] _ in
            self?.presentedRectDidChange()
        }
    }

    fileprivate static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "sublayers": NSNull(), "contents": NSNull(), "hidden": NSNull(),
        "backgroundColor": NSNull(),
    ]

    /// The page's pixels: a layer-hosting view (its layer is set before
    /// `wantsLayer`, so AppKit sizes the root with the view and never touches
    /// the remote layer under it). It has no subviews, as Apple asks of a
    /// layer-hosting view, and never takes the mouse.
    final class Surface: NSView {
        /// The shown context, 0 while none.
        private(set) var contextID: UInt32 = 0
        /// The root layer's background (``ChromiumHostPageView/backgroundFill``).
        var fill: CGColor? {
            didSet {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                root.backgroundColor = fill
                CATransaction.commit()
            }
        }
        private let root = CALayer()
        private var remote: CALayer?
        private let makeLayerHost: (UInt32) -> CALayer?

        init(frame: NSRect, makeLayerHost: @escaping (UInt32) -> CALayer?) {
            self.makeLayerHost = makeLayerHost
            super.init(frame: frame)
            root.masksToBounds = true
            root.actions = ChromiumHostPageView.noActions
            layer = root
            wantsLayer = true
            autoresizingMask = [.width, .height]
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        /// Unflipped: the page's root layer has its origin at the bottom left.
        override var isFlipped: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        /// ``ChromiumHostPageView/show(contextID:)``.
        func show(contextID id: UInt32) -> Bool {
            guard id != contextID else { return true }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            remote?.removeFromSuperlayer()
            remote = nil
            contextID = 0
            if id != 0, let layerHost = makeLayerHost(id) {
                layerHost.anchorPoint = .zero
                layerHost.position = .zero
                layerHost.actions = ChromiumHostPageView.noActions
                root.addSublayer(layerHost)
                remote = layerHost
                contextID = id
            }
            CATransaction.commit()
            return contextID == id
        }
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its wire.
extension ChromiumHostPageView {
    // MARK: Pacing

    /// The host dispatched this page's move or wheel tick in flight (input seq
    /// `seq`, nil: the oldest): the next waiting one leaves now. Main thread, in
    /// the host's ack order.
    func inputAcked(_ kind: ChromiumHostInputPacer.Paced, seq: UInt32? = nil) {
        guard let next = inputPacer?.acked(kind, seq: seq) else { return }
        write(next, paced: kind)
    }

    /// The host this page's input went to is gone (or a new one attached):
    /// nothing is in flight to it any more.
    func resetInputPacing() {
        inputPacer?.reset()
    }

    /// Every input frame of this view: through the pacer while ``pacesInput``,
    /// what waited first. The pacer's state changes before ``sink`` runs, so a
    /// sink that acks at once (a test's fake host) re-enters cleanly.
    ///
    /// - Returns: The receipt of `frame` itself when it left now.
    @discardableResult
    func sendInput(_ frame: ChromiumHostFrame) -> ChromiumHostInputReceipt? {
        guard inputPacer != nil else { return sink?(frame) }
        guard let release = inputPacer?.submit(frame) else { return nil }
        for ahead in release.ahead { write(ahead, paced: ChromiumHostInputPacer.paced(ahead)) }
        guard let now = release.frame else { return nil }
        return write(now, paced: ChromiumHostInputPacer.paced(now))
    }

    /// One frame the pacer released to ``sink``; a paced one the writer did not take gets no ack.
    @discardableResult
    private func write(_ frame: ChromiumHostFrame, paced: ChromiumHostInputPacer.Paced?) -> ChromiumHostInputReceipt? {
        let receipt = sink?(frame)
        if let paced {
            if let receipt { inputPacer?.written(paced, seq: receipt.seq) } else { inputPacer?.unsent(paced) }
        }
        return receipt
    }

    // MARK: Mouse

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard inputTarget == .view else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouse(event, phase: 1, button: 0)
    }
    public override func mouseUp(with event: NSEvent) { mouse(event, phase: 2, button: 0) }
    public override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouse(event, phase: 1, button: 2)
    }
    public override func rightMouseUp(with event: NSEvent) { mouse(event, phase: 2, button: 2) }
    public override func otherMouseDown(with event: NSEvent) { mouse(event, phase: 1, button: 1) }
    public override func otherMouseUp(with event: NSEvent) { mouse(event, phase: 2, button: 1) }
    public override func mouseMoved(with event: NSEvent) { mouse(event, phase: 0, button: 0) }
    public override func mouseDragged(with event: NSEvent) { mouse(event, phase: 0, button: 0) }
    public override func rightMouseDragged(with event: NSEvent) { mouse(event, phase: 0, button: 2) }
    public override func mouseExited(with event: NSEvent) { mouse(event, phase: 3, button: 0) }

    public override func scrollWheel(with event: NSEvent) {
        let point = pagePoint(event)
        // Pixel deltas, as cefclient's off-screen view reads them.
        let dy = event.cgEvent.map { Int32(clamping: $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) } ?? 0
        let dx = event.cgEvent.map { Int32(clamping: $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)) } ?? 0
        var frame = ChromiumHostFrame(.wheel, v: [point.x, point.y, dx, dy, Self.wheelPhase(event.phase), Self.wheelPhase(event.momentumPhase)],
                                      flags: UInt64(event.modifierFlags.rawValue), t0: Self.nanoseconds(event.timestamp))
        frame.ch = event.hasPreciseScrollingDeltas ? 1 : 0
        sendInput(frame)
    }

    /// An `NSEvent.Phase` as `cmux_shim_browser_send_wheel` takes it: 0 none,
    /// 1 may begin, 2 began, 3 changed, 4 ended, 5 cancelled. Chrome reads the
    /// same bits (`PhaseForNSEventPhase`, ui/events/blink/web_input_event_builders_mac.mm);
    /// a stationary tick, which the shim has no value for, is a change with no movement.
    static func wheelPhase(_ phase: NSEvent.Phase) -> Int32 {
        if phase.contains(.mayBegin) { return 1 }
        if phase.contains(.began) { return 2 }
        if phase.contains(.changed) || phase.contains(.stationary) { return 3 }
        if phase.contains(.ended) { return 4 }
        if phase.contains(.cancelled) { return 5 }
        return 0
    }

    private func mouse(_ event: NSEvent, phase: Int32, button: Int32) {
        let point = pagePoint(event)
        // Pressed buttons as bits: 1 left, 2 right, 4 middle (NSEvent's order, the wire's too).
        let buttons = Int32(truncatingIfNeeded: NSEvent.pressedMouseButtons & 0x7)
        sendInput(ChromiumHostFrame(.mouse, v: [point.x, point.y, phase, button, Int32(phase == 0 || phase == 3 ? 0 : event.clickCount), buttons],
                                    flags: UInt64(event.modifierFlags.rawValue), t0: Self.nanoseconds(event.timestamp)))
    }

    /// The event's point in page coordinates: points from the top left.
    private func pagePoint(_ event: NSEvent) -> (x: Int32, y: Int32) {
        let local = convert(event.locationInWindow, from: nil)
        return (Int32(local.x.rounded(.down)), Int32((bounds.height - local.y).rounded(.down)))
    }

    // MARK: Edit menu

    @objc public func copy(_ sender: Any?) { edit(0) }
    @objc public func cut(_ sender: Any?) { edit(1) }
    @objc public func paste(_ sender: Any?) { edit(2) }
    @objc public override func selectAll(_ sender: Any?) { edit(3) }
    @objc public func undo(_ sender: Any?) { edit(4) }
    @objc public func redo(_ sender: Any?) { edit(5) }

    private func edit(_ command: Int32) {
        sendInput(ChromiumHostFrame(.edit, v: [command]))
    }

    /// An event time (seconds since boot) as CLOCK_UPTIME_RAW nanoseconds, the host's clock too.
    static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        seconds > 0 ? UInt64(seconds * 1e9) : 0
    }
}
#endif

/// The page view's place on screen, as the host's window takes it.
nonisolated struct ChromiumHostGeometry: Equatable, Sendable {
    var width: Int32
    var height: Int32
    /// Bottom left of the view in screen points.
    var screenX: Int32
    var screenY: Int32
    var scaleMilli: Int32

    init(screenRect: CGRect, scale: CGFloat) {
        width = Int32(screenRect.width.rounded())
        height = Int32(screenRect.height.rounded())
        screenX = Int32(screenRect.minX.rounded())
        screenY = Int32(screenRect.minY.rounded())
        scaleMilli = Int32((scale * 1_000).rounded())
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
extension ChromiumHostGeometry {
    var frame: ChromiumHostFrame {
        ChromiumHostFrame(.geometry, v: [width, height, screenX, screenY, scaleMilli])
    }
}
#endif
