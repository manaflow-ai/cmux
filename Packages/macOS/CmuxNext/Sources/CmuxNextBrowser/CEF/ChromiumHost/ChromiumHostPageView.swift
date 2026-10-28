public import AppKit
import CmuxNextCompat
public import CmuxNextInput
import CmuxNextRemoteLayer
import CmuxNextWakeups
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
/// ``ChromiumHostConnection`` coalesces only under socket back-pressure;
/// keys in ChromiumHostPageView+Keys.swift; buttons past the third, pinch,
/// smart zoom and Force Touch pressure in ChromiumHostPageView+Gestures.swift).
/// With an owner that delivers the host's input acks (``pacesInput``,
/// ``inputAcked(_:seq:)``; the input ring's ``ChromiumHostInputRoute``), a
/// move or wheel tick still leaves at once when none of its kind is in
/// flight, and later ones wait coalesced for the ack
/// (``ChromiumHostInputPacer``); keys and clicks never
/// wait, and what waited leaves ahead of them. With
/// ``InputTarget/pageWindow`` the fork's transparent page window above takes
/// every event (in-process layer hosting), and this view takes none.
public final class ChromiumHostPageView: NSView, KeyEquivalentOwningSurface {
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
    /// The kind of page window in-process layer hosting shows here (`CEFLayerHosting.Widget.name`), for
    /// `debug.cef` `tracker.hosted_pages_by_widget`; nil for host mode's views. Set before the view enters a window.
    var hostedWidget: String?
    /// The view's size or screen place changed (only when the rect differs from the last one reported).
    var onGeometry: ((ChromiumHostGeometry) -> Void)? {
        didSet { observeWindow() }
    }
    /// Places the page on the display the view shows on (task 221, ChromiumHostPageView+Screen.swift);
    /// true when the placement went out. Called when that display differs from the last one placed,
    /// and again on a later change until a placement went out.
    var onScreenInfo: ((ChromiumHostScreenInfo) -> Bool)? {
        didSet { observeScreen() }
    }
    /// Reads a window's display; tests pass a stand-in.
    var screenInfoSource: @MainActor (NSWindow) -> ChromiumHostScreenInfo? = { ChromiumHostScreenInfo.of($0) }
    /// The display the view shows on, as last read; nil while the view is in no window or nobody takes it.
    var screenInfo: ChromiumHostScreenInfo?
    /// The display the page was last placed on; nil before a placement went out in this window.
    var placedScreenInfo: ChromiumHostScreenInfo?
    /// The window's screen and color profile notices, while someone takes the display.
    var screenEvents: [EventSubscription] = []
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
    /// A view over the page that fills it; nil shows the page (a pane's crash page is its chrome's sad tab).
    private(set) var crashOverlay: NSView?
    /// The page's last picture while no host shows it; only ``showStandIn(_:)``, ``coverWithSnapshot(_:)``
    /// (a hosted page past its hidden grace) and ``removeStandIn()`` set it.
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
    /// The page's cursor (host mode), shown over the page; nil shows none (in process the page window does).
    var pageCursor: CEFPageCursor? {
        didSet { if pageCursor != oldValue { shownCursor = pageCursor?.makeCursor(); showPageCursor() } }
    }
    /// ``pageCursor`` as AppKit shows it, made once per change.
    private(set) var shownCursor: NSCursor?
    /// Where cmux's views lie over the page (its ``CEFHostView``'s occlusion rects): no page cursor there.
    var cursorHoles: [CGRect] = [] {
        didSet { if cursorHoles != oldValue { placeCursorAreas() } }
    }
    /// The page cursor's `.cursorUpdate` areas: the visible page less ``coveredRects`` (ChromiumHostPageView+Cursor.swift).
    var cursorAreas: [NSTrackingArea] = []
    /// The shown page's accessibility (host mode; ChromiumHostPageView+Accessibility.swift).
    var remoteAccessibility = ChromiumHostRemoteAccessibility()
    /// Sends a page's accessibility request to the host and calls back with the page's token, nil
    /// for none (host mode: the pane host); nil in process, where the page window is its own
    /// accessibility tree.
    var accessibilityTokenSource: ((ChromiumHostAccessibilityRequest, @escaping ([UInt8]?) -> Void) -> Void)?
    /// AppKit's remote accessibility calls; tests pass stand-ins.
    var accessibilityBridge = ChromiumHostAccessibilityBridge.system
    /// Drops the remote element when its window closes: the element holds the window.
    var accessibilityWindowClose: EventSubscription?
    /// Drags from outside into the page (ChromiumHostPageView+Drag.swift); none until ``takeDrags(through:)``.
    let dragDestination = ChromiumHostDragDestination()
    /// The shown page's pointer lock, keyboard lock and fullscreen (task 229).
    let exclusiveAccess = ChromiumHostExclusiveAccess(cursor: .system)
    /// The page's autofill, password and `<datalist>` suggestions, drawn by cmux (task 061).
    lazy var suggestions = ChromiumHostSuggestionList(view: self)
    /// The window's part of the page's visibility (ChromiumHostPageView+Visibility.swift): hidden
    /// out of a window, in a minimized window or a hidden app; occluded in a covered window.
    let windowNode: VisibilityNode
    /// The page's visibility: the view's own hidden state under ``windowNode``.
    let pageNode: VisibilityNode
    /// Hears each change of ``pageVisibility``.
    var onPageVisibility: ((ChromiumHostPageVisibility) -> Void)?
    /// The window's state and notifications: AppKit's; tests pass their own.
    var visibilitySource = ChromiumHostPageVisibility.Source.appKit { didSet { observeVisibility() } }
    /// The window's minimize and occlusion notices while the view is in a window.
    var visibilitySubscriptions: [EventSubscription] = []
    /// Tells ``onPageVisibility`` of each flip of ``pageNode``.
    private var pageVisibilityWatch: VisibilitySubscription?

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
    /// Where composition, commit and edit-command ops go (``InputTarget/view``
    /// only): the same ordered stream as ``sink``, after the key frames sent before them
    /// (ChromiumHostPageView+TextInput.swift).
    var textInputSink: ((ChromiumHostTextInputOp) -> Void)?
    /// The word at a page point for Look Up (ChromiumHostPageView+LookUp.swift): the point in top-left
    /// page points, the window's backing scale, and the answer, nil for no word. Nil: AppKit's Look Up.
    var wordLookUp: ((CGPoint, CGFloat, @escaping (ChromiumHostLookUpWord?) -> Void) -> Void)?
    /// The page's text input: the state the host pushed and the input method's marked text.
    var textInput = ChromiumHostTextInput()
    /// Secure event input while a password field of the page has focus (ChromiumHostPageView+TextInput.swift).
    var passwordInput = ChromiumHostPasswordInput()
    /// Whether the page shown now is a cmux page (host mode's counterpart of ``CEFTab/pageThemeSurface``),
    /// asked of the page's owner (``CEFPaneHost/hostedPage()``): no macOS caret accessory over its fields.
    var showsCmuxPage: @MainActor () -> Bool = { false }
    /// Each scroll goes here first (the pane's swipe navigation, `CEFSwipeNavigation.handleHosted`); true when it
    /// took the scroll (a swipe tracks it), which then never reaches the page. Chrome's page view hands its
    /// scrolls to its history swiper the same way (`-[RenderWidgetHostViewCocoa scrollWheel:]`).
    var wheelGesture: ((NSEvent) -> Bool)?
    /// The input seq of the last wheel frame this view sent, 0 before any: WHEEL_ACKs of a gesture's own
    /// wheels carry later seqs.
    private(set) var lastWheelSeq: UInt32 = 0
    #endif

    private var lastGeometry: ChromiumHostGeometry?
    /// What moves the page on screen without changing this view's frame: the
    /// window's page update request (``ChildPageGeometryRegistry``). The window's
    /// layout owner (`WindowOverlayLayer`) makes it once per change after
    /// panes, dividers or the sidebar moved and after the window moved,
    /// resized or changed screen; the in-process `CEFHostView` re-places its
    /// page on the same request.
    private var pageUpdates: ChildPageGeometryRegistry.Registration?
    /// Where the window's screen notices arrive (`observeScreen`).
    let windowEventCenter: NotificationCenter

    /// - Parameters:
    ///   - inputTarget: who takes the page's input.
    ///   - makeLayerHost: the layer that shows a context id; a `CALayerHost` by
    ///     default (tests pass one that fails, or a plain layer).
    ///   - windowEventCenter: where the window's screen notices arrive;
    ///     `.default` in the app, a private center in tests.
    init(frame: NSRect, inputTarget: InputTarget,
         makeLayerHost: @escaping (UInt32) -> CALayer? = { ChromiumHostPageView.layerHost(contextID: $0) },
         windowEventCenter: NotificationCenter = .default) {
        self.inputTarget = inputTarget
        self.windowEventCenter = windowEventCenter
        surface = Surface(frame: NSRect(origin: .zero, size: frame.size), makeLayerHost: makeLayerHost)
        let windowNode = VisibilityNode(root: "chromium-page.window", own: .hidden)
        self.windowNode = windowNode
        pageNode = VisibilityNode("chromium-page", parent: windowNode)
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        addSubview(surface)
        #if DEBUG || CMUX_BENCH_HOOKS
        if inputTarget == .view {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self))
        }
        #endif
        pageVisibilityWatch = pageNode.subscribe(owner: "ChromiumHostPageView.pageVisibility") { [weak self] visibility in
            self?.onPageVisibility?(ChromiumHostPageVisibility(visibility))
        }
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
        if !focused { exclusiveAccess.focusLost() }
        onFocusChange?(focused)
        #if DEBUG || CMUX_BENCH_HOOKS
        sendInput(ChromiumHostFrame(.focus, v: [focused ? 1 : 0]))
        if !focused { textInputDidResign() }
        passwordInput.focused = focused
        updatePasswordInput()
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
        if let overlay {
            overlay.frame = bounds
            overlay.autoresizingMask = [.width, .height]
            addSubview(overlay, positioned: .above, relativeTo: standIn ?? surface)
        }
        placeCursorAreas()
        return true
    }

    /// Shows context `id` (0 shows nothing: the page went away, or its host
    /// ended or restarts). False when `id` is not 0 and nothing can show it (no
    /// `CALayerHost`): an in-process caller gives the page its own window back
    /// instead of leaving it blank.
    @discardableResult
    func show(contextID id: UInt32) -> Bool {
        let changed = id != surface.contextID
        let shown = surface.show(contextID: id)
        // Another page window or host: the page's accessibility element is of the old one.
        if changed { resetRemoteAccessibility() }
        return shown
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
            CEFHostView.trackerStats.countHostedPage(widget: hostedWidget, delta: 1)
        } else if window != nil, newWindow == nil {
            CEFHostView.trackerStats.countHostedPage(widget: hostedWidget, delta: -1)
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
        observeVisibility()
        observeScreen()
        followWindowForExclusiveAccess()
        // Another window: the page is placed again, at the view's origin in that window.
        screenInfo = nil
        placedScreenInfo = nil
        // The host made the page's element for the old window's token.
        resetRemoteAccessibility()
        onWindowChange?(window != nil)
        #if DEBUG || CMUX_BENCH_HOOKS
        passwordInputWindowChanged()
        #endif
        if window == nil {
            lastGeometry = nil
            keyDowns.removeAll()
            exclusiveAccess.showing(nil)
            onLeftWindow?()
        } else {
            presentedRectDidChange()
            screenMayHaveChanged()
        }
    }

    // MARK: Geometry

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        presentedRectDidChange()
        // A view below 1 x 1 point has no page display: its placement goes out once it has a size.
        placeIfNeeded()
    }

    public override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        presentedRectDidChange()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        presentedRectDidChange()
        screenMayHaveChanged()
    }

    /// Reports the page's screen rect when it differs from the last one
    /// reported; an unchanged rect costs one comparison. Returns whether it reported.
    @discardableResult
    private func presentedRectDidChange() -> Bool {
        guard let onGeometry, let window, let screen = presentedScreenRect else { return false }
        let geometry = ChromiumHostGeometry(screenRect: screen, scale: window.backingScaleFactor)
        guard geometry != lastGeometry else { return false }
        lastGeometry = geometry
        onGeometry(geometry)
        return true
    }

    /// The view's rect in screen points; nil in no window or below 1 x 1 point.
    var presentedScreenRect: CGRect? {
        guard let window, bounds.width >= 1, bounds.height >= 1 else { return nil }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    /// Follows the window's page update request only while someone takes the geometry.
    private func observeWindow() {
        guard onGeometry != nil, let window else {
            pageUpdates = nil
            return
        }
        pageUpdates = ChildPageGeometryRegistry.of(window).register { [weak self] _ in
            self?.presentedRectDidChange() ?? false
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
        guard inputPacer != nil else { return write(frame, paced: nil) }
        guard let release = inputPacer?.submit(frame) else { return nil }
        for ahead in release.ahead { write(ahead, paced: ChromiumHostInputPacer.paced(ahead)) }
        guard let now = release.frame else { return nil }
        return write(now, paced: ChromiumHostInputPacer.paced(now))
    }

    /// Sends the moves and wheel ticks that wait now, ahead of input that goes another way (a
    /// text input op on the control stream).
    func flushWaitingInput() {
        guard let ahead = inputPacer?.flush() else { return }
        for frame in ahead { write(frame, paced: ChromiumHostInputPacer.paced(frame)) }
    }

    /// One frame to ``sink``, at once or as the pacer released it; a paced one the writer did not take
    /// gets no ack. A wheel the writer took is the newest one sent (``lastWheelSeq``).
    @discardableResult
    private func write(_ frame: ChromiumHostFrame, paced: ChromiumHostInputPacer.Paced?) -> ChromiumHostInputReceipt? {
        let receipt = sink?(frame)
        if let receipt, frame.kind == .wheel { lastWheelSeq = receipt.seq }
        if let paced {
            if let receipt { inputPacer?.written(paced, seq: receipt.seq) } else { inputPacer?.unsent(paced) }
        }
        return receipt
    }

    // MARK: Mouse

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
    public override func otherMouseDown(with event: NSEvent) { otherMouse(event, phase: 1) }
    public override func otherMouseUp(with event: NSEvent) { otherMouse(event, phase: 2) }
    // Moves and drags go to the host at once, as a browser process forwards them: Chromium's renderer aligns
    // them to its own frame (main_thread_event_queue.cc), and on back-pressure the wire keeps only the latest
    // in its slot (ChromiumHostConnection).
    public override func otherMouseDragged(with event: NSEvent) { otherMouse(event, phase: 0) } // input-coalesce: native (the renderer aligns it)
    public override func mouseMoved(with event: NSEvent) { mouse(event, phase: 0, button: 0) } // input-coalesce: native (the renderer aligns it)
    public override func mouseDragged(with event: NSEvent) { mouse(event, phase: 0, button: 0) } // input-coalesce: native (the renderer aligns it)
    public override func rightMouseDragged(with event: NSEvent) { mouse(event, phase: 0, button: 2) } // input-coalesce: native (the renderer aligns it)
    public override func mouseExited(with event: NSEvent) { mouse(event, phase: 3, button: 0) }

    public override func scrollWheel(with event: NSEvent) {
        if wheelGesture?(event) == true { return }
        let point = pagePoint(event)
        sendInput(ChromiumHostFrame.wheel(.init(
            x: point.x, y: point.y, deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY),
            precise: event.hasPreciseScrollingDeltas, phase: event.phase.rawValue, momentumPhase: event.momentumPhase.rawValue,
            modifierFlags: UInt64(event.modifierFlags.rawValue), time: Self.nanoseconds(event.timestamp))))
    }

    /// A down ends an open composition first, keeping its text (``textInputMouseDown()``).
    func mouse(_ event: NSEvent, phase: Int32, button: Int32) {
        if exclusiveAccess.takesMove(event, phase: phase) { return }
        if phase == 1 { textInputMouseDown() }
        let point = pagePoint(event)
        let buttons = Self.pressedButtons()
        sendInput(ChromiumHostFrame(.mouse, v: [point.x, point.y, phase, button, Int32(phase == 0 || phase == 3 ? 0 : event.clickCount), buttons],
                                    flags: UInt64(event.modifierFlags.rawValue), t0: Self.nanoseconds(event.timestamp)))
    }

    /// The event's point in page coordinates: points from the top left.
    func pagePoint(_ event: NSEvent) -> (x: Int32, y: Int32) {
        let local = convert(event.locationInWindow, from: nil)
        return (Int32(local.x.rounded(.down)), Int32((bounds.height - local.y).rounded(.down)))
    }

    /// An event time (seconds since boot) as CLOCK_UPTIME_RAW nanoseconds, the host's clock too: the input latency
    /// slot's `generated` time, so the host's presentation report by this time finds the slot.
    static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        InputLatencyTracker.eventNanos(seconds)
    }
}
#endif
