public import AppKit
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
    public override var acceptsFirstResponder: Bool { true }
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
        ChromiumHostFrame(.geometry, v: [width, height, screenX, screenY, scaleMilli])
    }
}
