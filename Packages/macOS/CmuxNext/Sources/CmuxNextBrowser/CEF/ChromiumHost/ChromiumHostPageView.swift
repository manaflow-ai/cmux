public import AppKit
public import CmuxNextDesign
import QuartzCore

/// A page of a Chromium host app in a cmux pane (prototype behind
/// `browserHost.helperPrototype`; plans/cmux-next/cef-helper-app-DESIGN.md).
///
/// Pixels: the host's Core Animation context, shown with the same
/// `CALayerHost` an in-process hosted page uses
/// (``CEFHostedPageView/layerHost(contextID:)``), so the page composites in
/// this window's own layer tree. Input: this view is the page's input target;
/// it turns its mouse, scroll and key events into wire frames for the host
/// and Edit menu actions into edit frames. It holds no session: ``sink``
/// takes the frames, ``onGeometry`` the size and screen place.
///
/// Remote Cocoa (``remoteCocoa``, fork API 37): neither. The page's own `WebContentsViewCocoa` arrives as a subview
/// (made in this process by Chromium's remote_cocoa bridges; ``onPageView``) and handles its own input, IME, cursor,
/// drag and drawing; this view only holds it, so it takes no first responder and forwards nothing.
public final class ChromiumHostPageView: NSView {
    /// Where frames for the host go.
    var sink: ((ChromiumHostFrame) -> Void)?
    /// The view's size or screen place changed.
    var onGeometry: ((ChromiumHostGeometry) -> Void)?
    /// The shown context, 0 while none.
    private(set) var contextID: UInt32 = 0
    private let root = CALayer()
    private var remote: CALayer?
    private var tracking: NSTrackingArea?
    private var lastGeometry: ChromiumHostGeometry?
    /// The remote Cocoa resize probe's last layer chain (written again only when it changes).
    private var lastProbeChain = ""
    /// Remote Cocoa: the page's views go into ``remoteContainer``; nothing is forwarded.
    var remoteCocoa = false {
        didSet {
            if remoteCocoa, remoteContainer.superview == nil { addSubview(remoteContainer) }
            #if DEBUG || CMUX_BENCH_HOOKS
            if remoteCocoa { ChromiumRemoteClickProbe.installIfEnabled() }
            #endif
        }
    }
    /// Remote Cocoa: a subview arrived (the page's `WebContentsViewCocoa`).
    var onPageView: ((NSView) -> Void)? {
        get { remoteContainer.onSubview }
        set { remoteContainer.onSubview = newValue }
    }
    /// Remote Cocoa: the view the bridges put the page's `WebContentsViewCocoa` into (the id cmux names to the host).
    /// A plain layer-backed view filling this one: this view hosts its own root layer, and AppKit does not manage the
    /// layers of a layer-hosting view's subviews.
    let remoteContainer = ChromiumRemotePageContainer()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        root.masksToBounds = true
        root.actions = Self.noActions
        layer = root
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Unflipped: the host's root layer has its origin at the bottom left.
    public override var isFlipped: Bool { false }
    public override var acceptsFirstResponder: Bool { !remoteCocoa }

    /// Remote Cocoa: the page's `RenderWidgetHostViewCocoa` (the view that takes keys), when it is here.
    public var pageKeyView: NSView? {
        var stack = remoteContainer.subviews
        while let view = stack.popLast() {
            if NSStringFromClass(type(of: view)).hasSuffix("RenderWidgetHostViewCocoa") { return view }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Shows context `id` (0 shows nothing: the host ended or restarts).
    func show(contextID id: UInt32) {
        guard id != contextID else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        remote?.removeFromSuperlayer()
        remote = nil
        contextID = 0
        if id != 0, let host = CEFHostedPageView.layerHost(contextID: id) {
            host.anchorPoint = .zero
            host.position = .zero
            host.actions = Self.noActions
            root.addSublayer(host)
            remote = host
            contextID = id
        }
        CATransaction.commit()
    }

    // MARK: Geometry

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportGeometry()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportGeometry()
        if window == nil {
            ResizeStepTimes.precommitProbes[ObjectIdentifier(self)] = nil
        } else {
            ResizeStepTimes.precommitProbes[ObjectIdentifier(self)] = { [weak self] in self?.probeRemoteGeometry() }
        }
    }

    // MARK: The remote Cocoa resize probe (measurement builds)

    /// During a window drag the remote pages sat off their panes by the panes' height change (slope 0.50 of the window's,
    /// r 1.00), and flipping ``remoteContainer`` changed nothing (approaches/remote-cocoa rc-win-2-fix). Just before each
    /// step's commit this writes what that commit shows, from this pane down to the compositor's layer: this view, the
    /// container, the page's `WebContentsViewCocoa` and `RenderWidgetHostViewCocoa` (each its frame in the window,
    /// bottom-left points, and whether it is flipped), the render view's backing layer, its geometry-flipped layer
    /// (`ui::DisplayCALayerTree`), and that layer's sublayers (the `CALayerHost`: frame, position, anchor point,
    /// context id). `pane_top - rwhv_top` and the layers' offsets give where this process puts the page's top.
    private func probeRemoteGeometry() {
        guard remoteCocoa, window != nil else { return }
        func r(_ rect: NSRect) -> String { String(format: "%.1f,%.1f,%.1f,%.1f", rect.minX, rect.minY, rect.width, rect.height) }
        var line = " pane=\(r(convert(bounds, to: nil))) cont=\(r(remoteContainer.convert(remoteContainer.bounds, to: nil)))"
        line += " root=\(r(root.frame)) root_gf=\(root.isGeometryFlipped ? 1 : 0)"
        line += " cont_flipped=\(remoteContainer.isFlipped ? 1 : 0)"
        line += " cont_layer=\(remoteContainer.layer.map { r($0.frame) + " gf=\($0.isGeometryFlipped ? 1 : 0)" } ?? "-")"
        if let page = remoteContainer.subviews.first {
            line += " wcvc=\(r(page.convert(page.bounds, to: nil))) wcvc_in_cont=\(r(page.frame)) wcvc_flipped=\(page.isFlipped ? 1 : 0)"
            line += " wcvc_layer=\(page.layer.map { r($0.frame) + " gf=\($0.isGeometryFlipped ? 1 : 0)" } ?? "-")"
        }
        guard let rwhv = pageKeyView else { return ResizeStepTimes.note("rc_geom", ms: 0, detail: line) }
        line += " rwhv=\(r(rwhv.convert(rwhv.bounds, to: nil))) rwhv_in_super=\(r(rwhv.frame)) rwhv_flipped=\(rwhv.isFlipped ? 1 : 0)"
        line += " rwhv_super_flipped=\(rwhv.superview?.isFlipped == true ? 1 : 0)"
        ResizeStepTimes.note("rc_geom", ms: 0, detail: line)
        guard let background = rwhv.layer else { return }
        var layers = " bg=\(r(background.frame)) bg_bounds=\(r(background.bounds)) bg_gf=\(background.isGeometryFlipped ? 1 : 0)"
        var host: CALayer?
        for (i, sub) in (background.sublayers ?? []).enumerated() {
            layers += " sub\(i)=\(r(sub.frame)) gf=\(sub.isGeometryFlipped ? 1 : 0) mask=\(sub.autoresizingMask.rawValue)"
            for (j, leaf) in (sub.sublayers ?? []).enumerated() {
                let context = (leaf.value(forKey: "contextId") as? NSNumber)?.uint32Value ?? 0
                layers += " leaf\(i).\(j)=\(NSStringFromClass(type(of: leaf))):\(r(leaf.frame))"
                layers += String(format: " pos=%.1f,%.1f anchor=%.2f,%.2f", leaf.position.x, leaf.position.y,
                                 leaf.anchorPoint.x, leaf.anchorPoint.y)
                layers += " ctx=\(context) mask=\(leaf.autoresizingMask.rawValue)"
                if sub.isGeometryFlipped, host == nil { host = leaf }
            }
        }
        if let host {
            // Where the compositor's layer (the page hangs from its origin) and one point along its y land in the window's
            // top layer, beside this pane's top and bottom there: whether it sits at the pane's top, and which way its y
            // runs on screen.
            var top: CALayer = host
            var chain: [String] = []
            while let up = top.superlayer {
                chain.append("\(NSStringFromClass(type(of: up))):\(up.isGeometryFlipped ? 1 : 0):\(r(up.frame))")
                top = up
            }
            let origin = host.convert(CGPoint.zero, to: top)
            let along = host.convert(CGPoint(x: 0, y: 1), to: top)
            let paneTop = root.convert(CGPoint(x: 0, y: root.bounds.maxY), to: top)
            let paneBottom = root.convert(CGPoint(x: 0, y: root.bounds.minY), to: top)
            layers += String(format: " host_origin=%.1f,%.1f host_y1=%.1f,%.1f pane_top=%.1f pane_bottom=%.1f top_gf=%ld",
                             origin.x, origin.y, along.x, along.y, paneTop.y, paneBottom.y, top.isGeometryFlipped ? 1 : 0)
            let joined = chain.joined(separator: "|")
            if joined != lastProbeChain {
                lastProbeChain = joined
                ResizeStepTimes.note("rc_chain", ms: 0, detail: " " + joined)
            }
        }
        ResizeStepTimes.note("rc_layers", ms: 0, detail: layers)
    }

    public override func layout() {
        super.layout()
        reportGeometry()
    }

    private func reportGeometry() {
        guard let window, bounds.width >= 1, bounds.height >= 1 else { return }
        let screen = window.convertToScreen(convert(bounds, to: nil))
        let geometry = ChromiumHostGeometry(screenRect: screen, scale: window.backingScaleFactor)
        guard geometry != lastGeometry else { return }
        lastGeometry = geometry
        onGeometry?(geometry)
    }

    // MARK: Focus

    public override func becomeFirstResponder() -> Bool {
        if remoteCocoa { return false }
        sink?(ChromiumHostFrame(.focus, v: .init(1)))
        return true
    }

    public override func resignFirstResponder() -> Bool {
        sink?(ChromiumHostFrame(.focus, v: .init(0)))
        return true
    }

    // MARK: Mouse

    /// Its own tracking area only where no layout screen serves it (``PanePointerFollowing``): in a pane the screen's one
    /// area delivers its moves, so a page that moves with its pane costs AppKit no tracking-area work (RESIZE MAIN BUDGET).
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard !isServedByPanePointerArea else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseDown(with event: NSEvent) {
        #if DEBUG || CMUX_BENCH_HOOKS
        if remoteCocoa, ChromiumRemoteClickProbe.isEnabled {
            ChromiumRemoteClickProbe.log("page_view_mouse_down", event, " dropped=1 (remote mode forwards nothing)")
        }
        #endif
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

    public override func scrollWheel(with event: NSEvent) { // perf-hot: 5us cef-host-input (every scroll event)
        guard !remoteCocoa else { return super.scrollWheel(with: event) }
        let point = pagePoint(event)
        // Pixel deltas, as cefclient's off-screen view reads them. `cgEvent` is read once per event, as
        // Chromium's own Mac wheel path (`WebMouseWheelEventBuilder`) reads it.
        let cgEvent = event.cgEvent
        let dy = cgEvent.map { Int32($0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) } ?? 0
        let dx = cgEvent.map { Int32($0.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)) } ?? 0
        sink?(ChromiumHostFrame(.wheel, v: .init(point.x, point.y, dx, dy), flags: UInt64(event.modifierFlags.rawValue),
                                t0: Self.nanoseconds(event.timestamp)))
    }

    private func mouse(_ event: NSEvent, phase: Int32, button: Int32) { // perf-hot: 5us cef-host-input (every mouse event)
        guard !remoteCocoa else { return }
        let point = pagePoint(event)
        // Pressed buttons as bits: 1 left, 2 right, 4 middle (NSEvent's order, the wire's too).
        let buttons = Int32(truncatingIfNeeded: NSEvent.pressedMouseButtons & 0x7)
        sink?(ChromiumHostFrame(.mouse, v: .init(point.x, point.y, phase, button, Int32(phase == 0 || phase == 3 ? 0 : event.clickCount), buttons),
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

    private func key(_ event: NSEvent, phase: Int32) { // perf-hot: 5us cef-host-input (every key event)
        guard !remoteCocoa else { return }
        var frame = ChromiumHostFrame(.key, v: .init(phase, Int32(event.keyCode), event.type == .flagsChanged ? 0 : (event.isARepeat ? 1 : 0)),
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
        sink?(ChromiumHostFrame(.edit, v: .init(command)))
    }

    /// An event time (seconds since boot) as CLOCK_UPTIME_RAW nanoseconds, the host's clock too.
    static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        seconds > 0 ? UInt64(seconds * 1e9) : 0
    }

    private static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "sublayers": NSNull(), "contents": NSNull(), "hidden": NSNull(),
    ]
}

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

    var frame: ChromiumHostFrame {
        ChromiumHostFrame(.geometry, v: .init(width, height, screenX, screenY, scaleMilli))
    }
}

/// In a pane the layout screen's one tracking area hit-tests the pointer and calls these, while the window is key (as
/// the page's own `.activeInKeyWindow` area did). The page sets its own cursor (the host's cursor frames).
extension ChromiumHostPageView: PanePointerFollowing {
    public func panePointerCursor(at point: NSPoint) -> NSCursor? { nil }
    public func panePointerEntered(with event: NSEvent) {}
    public func panePointerMoved(with event: NSEvent) { if window?.isKeyWindow == true { mouseMoved(with: event) } }
    public func panePointerExited(with event: NSEvent) { if window?.isKeyWindow == true { mouseExited(with: event) } }
}

/// The view a remote Cocoa page's `WebContentsViewCocoa` goes into (``ChromiumHostPageView/remoteContainer``).
final class ChromiumRemotePageContainer: NSView {
    var onSubview: ((NSView) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Flipped, so the page stays pinned to the pane's top while its size catches up. The host places the page's
    /// `WebContentsViewCocoa` here with Views' top-left bounds (`WebContentsNSViewBridge::SetBounds`). In an unflipped
    /// view the bridge turns that Y around with the host's own superview height, which trails this view's height
    /// during a live resize, so the whole page moved up or down by the height change until the host caught up
    /// (a corner drag: 60 pt at p50 for the whole drag). Flipped, the bridge takes the top-left Y as it is, and a
    /// stale size shows only at the page's bottom edge, as an in-process page's does.
    override var isFlipped: Bool { true }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if let newSuperview { frame = newSuperview.bounds }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        onSubview?(subview)
    }
}
