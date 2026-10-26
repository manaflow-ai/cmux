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
/// around it, with no WindowServer round trip and no `NSWindow` per page in
/// cmux. A context id is a WindowServer name, not a pointer: the same view
/// shows a page whose browser runs in another process. Chromium shows its GPU
/// process's output the same way (`ui/accelerated_widget_mac/display_ca_layer_tree.mm`).
///
/// Around the pixels: the page's background fill while no context shows (a
/// host starting or restarting), a crash overlay slot over the page, and the
/// geometry the page's owner needs, reported only when the presented rect
/// changed (PATTERNS P8).
///
/// Input (``InputTarget``): with ``InputTarget/view`` this view is the page's
/// input target and first responder (host mode: mouse, scroll, keys and Edit
/// menu actions become wire frames for ``sink``). With
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
    /// The view's size or screen place changed (only when the rect differs from the last one reported).
    var onGeometry: ((ChromiumHostGeometry) -> Void)? {
        didSet { observeWindow() }
    }
    /// The view left its window (its pane closed, or it moved out of every window).
    var onLeftWindow: (() -> Void)?
    /// The shown context, 0 while none.
    private(set) var contextID: UInt32 = 0
    /// The page's background, shown wherever the page's own pixels are not
    /// (no context yet, a restart). Nil is see-through, as the in-process page
    /// window needs. Chromium fills its page view the same way
    /// (`RenderWidgetHostNSViewBridge::SetBackgroundColor`,
    /// `content/app_shim_remote_cocoa/render_widget_host_ns_view_bridge.mm`).
    var backgroundFill: CGColor? {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.backgroundColor = backgroundFill
            CATransaction.commit()
        }
    }
    /// A view over the page that fills it (the crash page, p01-process-082); nil shows the page.
    /// It takes the mouse even while the page window takes the page's input.
    var crashOverlay: NSView? {
        didSet {
            guard crashOverlay !== oldValue else { return }
            oldValue?.removeFromSuperview()
            guard let crashOverlay else { return }
            crashOverlay.frame = bounds
            crashOverlay.autoresizingMask = [.width, .height]
            addSubview(crashOverlay)
        }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Where frames for the host go (``InputTarget/view`` only).
    var sink: ((ChromiumHostFrame) -> Void)?
    private var tracking: NSTrackingArea?
    #endif

    private let root = CALayer()
    /// Holds the remote layer under every subview's layer (the crash overlay's).
    private let content = CALayer()
    private var remote: CALayer?
    private let makeLayerHost: (UInt32) -> CALayer?
    private var lastGeometry: ChromiumHostGeometry?
    /// The window's moves and screen changes: they move the page on screen
    /// without changing this view's frame.
    private var windowObservations: [MainActorObservation] = []

    /// - Parameters:
    ///   - inputTarget: who takes the page's input.
    ///   - makeLayerHost: the layer that shows a context id; a `CALayerHost` by
    ///     default (tests pass one that fails, or a plain layer).
    init(frame: NSRect, inputTarget: InputTarget,
         makeLayerHost: @escaping (UInt32) -> CALayer? = { ChromiumHostPageView.layerHost(contextID: $0) }) {
        self.inputTarget = inputTarget
        self.makeLayerHost = makeLayerHost
        super.init(frame: frame)
        // Layer-hosting view (layer set before wantsLayer): AppKit sizes the
        // root with the view and never touches the remote layer under it.
        root.masksToBounds = true
        root.actions = Self.noActions
        content.anchorPoint = .zero
        content.position = .zero
        content.actions = Self.noActions
        root.addSublayer(content)
        layer = root
        wantsLayer = true
        autoresizingMask = [.width, .height]
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

    /// With ``InputTarget/pageWindow`` only the crash overlay takes the mouse;
    /// the page's input goes to the page window above.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        switch inputTarget {
        case .view: super.hitTest(point)
        case .pageWindow: crashOverlay.flatMap { $0.hitTest(convert(point, from: superview)) }
        }
    }

    /// Shows context `id` (0 shows nothing: the page went away, or its host
    /// ended or restarts). False when `id` is not 0 and nothing can show it (no
    /// `CALayerHost`): an in-process caller gives the page its own window back
    /// instead of leaving it blank.
    @discardableResult
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
            layerHost.actions = Self.noActions
            content.addSublayer(layerHost)
            remote = layerHost
            contextID = id
        }
        CATransaction.commit()
        return contextID == id
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
        if window == nil {
            lastGeometry = nil
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

    /// The page's rect on screen may have changed without this view's frame
    /// changing (an ancestor moved, the pane's presented rect moved): the
    /// owner calls this for the panes whose rect changed (P8), and a rect
    /// equal to the last one reported costs one comparison.
    func presentedRectDidChange() {
        guard let onGeometry, let window, bounds.width >= 1, bounds.height >= 1 else { return }
        let screen = window.convertToScreen(convert(bounds, to: nil))
        let geometry = ChromiumHostGeometry(screenRect: screen, scale: window.backingScaleFactor)
        guard geometry != lastGeometry else { return }
        lastGeometry = geometry
        onGeometry(geometry)
    }

    /// Follows the window's moves and screen changes only while someone takes the geometry.
    private func observeWindow() {
        guard onGeometry != nil, let window else {
            windowObservations = []
            return
        }
        windowObservations = [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification].map { name in
            MainActorObservation(name, object: window) { [weak self] in self?.presentedRectDidChange() }
        }
    }

    private static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "sublayers": NSNull(), "contents": NSNull(), "hidden": NSNull(),
        "backgroundColor": NSNull(),
    ]
}

#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its wire.
extension ChromiumHostPageView {
    // MARK: Focus

    public override func becomeFirstResponder() -> Bool {
        sink?(ChromiumHostFrame(.focus, v: [1]))
        return true
    }

    public override func resignFirstResponder() -> Bool {
        sink?(ChromiumHostFrame(.focus, v: [0]))
        return true
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
        let dy = event.cgEvent.map { Int32($0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) } ?? 0
        let dx = event.cgEvent.map { Int32($0.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)) } ?? 0
        sink?(ChromiumHostFrame(.wheel, v: [point.x, point.y, dx, dy], flags: UInt64(event.modifierFlags.rawValue),
                                t0: Self.nanoseconds(event.timestamp)))
    }

    private func mouse(_ event: NSEvent, phase: Int32, button: Int32) {
        let point = pagePoint(event)
        // Pressed buttons as bits: 1 left, 2 right, 4 middle (NSEvent's order, the wire's too).
        let buttons = Int32(truncatingIfNeeded: NSEvent.pressedMouseButtons & 0x7)
        sink?(ChromiumHostFrame(.mouse, v: [point.x, point.y, phase, button, Int32(phase == 0 || phase == 3 ? 0 : event.clickCount), buttons],
                                flags: UInt64(event.modifierFlags.rawValue), t0: Self.nanoseconds(event.timestamp)))
    }

    /// The event's point in page coordinates: points from the top left.
    private func pagePoint(_ event: NSEvent) -> (x: Int32, y: Int32) {
        let local = convert(event.locationInWindow, from: nil)
        return (Int32(local.x.rounded(.down)), Int32((bounds.height - local.y).rounded(.down)))
    }

    // MARK: Keys

    public override func keyDown(with event: NSEvent) { key(event, phase: 0) }
    public override func keyUp(with event: NSEvent) { key(event, phase: 1) }
    public override func flagsChanged(with event: NSEvent) { key(event, phase: 2) }

    private func key(_ event: NSEvent, phase: Int32) {
        var frame = ChromiumHostFrame(.key, v: [phase, Int32(event.keyCode), event.type == .flagsChanged ? 0 : (event.isARepeat ? 1 : 0)],
                                      flags: UInt64(event.modifierFlags.rawValue), t0: Self.nanoseconds(event.timestamp))
        if event.type != .flagsChanged {
            frame.ch = event.characters?.utf16.first ?? 0
            frame.unmod = event.charactersIgnoringModifiers?.utf16.first ?? 0
        }
        sink?(frame)
    }

    // MARK: Edit menu

    @objc public func copy(_ sender: Any?) { edit(0) }
    @objc public func cut(_ sender: Any?) { edit(1) }
    @objc public func paste(_ sender: Any?) { edit(2) }
    @objc public override func selectAll(_ sender: Any?) { edit(3) }
    @objc public func undo(_ sender: Any?) { edit(4) }
    @objc public func redo(_ sender: Any?) { edit(5) }

    private func edit(_ command: Int32) {
        sink?(ChromiumHostFrame(.edit, v: [command]))
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
