#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its wire.
public import AppKit

/// The host page view's mouse input past clicks, moves and the wheel (task 054 of
/// plans/cmux-next/chrome-parity/p01-process.md): the extra mouse buttons, the trackpad pinch,
/// smart zoom and Force Touch pressure. Chrome's page view sends each to its browser process
/// (content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm: `-otherMouseDown:`,
/// `-magnifyWithEvent:`, `-smartMagnifyWithEvent:`, `-pressureChangeWithEvent:`), on the same
/// ordered pipe as clicks and keys (`RenderWidgetHostNSViewHost`: `RouteOrProcessMouseEvent`,
/// `GestureBegin`, `GestureUpdate`, `GestureEnd`, `SmartMagnify`); here each is one wire frame
/// (kMouse, kGesture in ChromiumHost/src/chromium_host_wire.h) on the ordered input stream.
extension ChromiumHostPageView {
    /// The kGesture types (chromium_host_wire.h).
    enum GestureType: Int32, Sendable {
        case pinchBegin = 0
        case pinchUpdate = 1
        case pinchEnd = 2
        case smartMagnify = 3
        case pressure = 4
    }

    /// One kGesture frame's own fields: its type, v3 (the scale step or the pressure, x 1e6) and v4
    /// (the pressure stage).
    struct Gesture: Equatable, Sendable {
        var type: GestureType
        var value: Int32 = 0
        var stage: Int32 = 0
    }

    // MARK: Buttons

    /// The middle button and the buttons past it. AppKit numbers them 2, 3 (Back), 4 (Forward) and up;
    /// the wire, as Chrome's `WebPointerProperties::Button`, 1 middle, 3 back, 4 forward. A button past
    /// the fifth has no web button and sends nothing.
    func otherMouse(_ event: NSEvent, phase: Int32) {
        guard let button = Self.wireButton(buttonNumber: event.buttonNumber) else { return }
        mouse(event, phase: phase, button: button)
    }

    /// The wire's button for an AppKit button number (0 left, 1 right, 2 middle, 3 back, 4 forward,
    /// as `ui/events/blink/web_input_event_builders_mac.mm` maps them); nil past the fifth.
    static func wireButton(buttonNumber: Int) -> Int32? {
        switch buttonNumber {
        case 0: 0
        case 1: 2
        case 2: 1
        case 3: 3
        case 4: 4
        default: nil
        }
    }

    /// The pressed buttons as the wire's bits: 1 left, 2 right, 4 middle, 8 back, 16 forward, which are
    /// `NSEvent.pressedMouseButtons`' bits and the DOM's `MouseEvent.buttons` both.
    static func pressedButtons(_ pressed: Int = NSEvent.pressedMouseButtons) -> Int32 {
        Int32(truncatingIfNeeded: pressed & 0x1f)
    }

    // MARK: Pinch and smart zoom

    /// A trackpad pinch: begin, one update per step, end, as `-magnifyWithEvent:` sends
    /// GestureBegin, GestureUpdate and GestureEnd.
    public override func magnify(with event: NSEvent) {
        sendGesture(Self.pinch(phase: event.phase, magnification: event.magnification), event)
    }

    /// A two-finger double tap: Chrome's SmartMagnify, which zooms to the element under the pointer.
    public override func smartMagnify(with event: NSEvent) {
        sendGesture([Gesture(type: .smartMagnify)], event)
    }

    /// The kGesture frames of one magnify event. An update's value
    /// is the scale step x 1e6, 1 + magnification (`WebGestureEventBuilder::Build`'s pinch scale). A
    /// magnify with no phase (a mouse with a pinch control, a synthesized event) is a whole pinch.
    static func pinch(phase: NSEvent.Phase, magnification: CGFloat) -> [Gesture] {
        let update = Gesture(type: .pinchUpdate, value: millionths(1 + magnification))
        if phase.contains(.ended) || phase.contains(.cancelled) { return [Gesture(type: .pinchEnd)] }
        if phase.contains(.began) { return [Gesture(type: .pinchBegin), update] }
        if phase.isEmpty { return [Gesture(type: .pinchBegin), update, Gesture(type: .pinchEnd)] }
        return [update]
    }

    // MARK: Force Touch

    /// A Force Touch click's pressure and stage (1 click, 2 force click), in order with the click,
    /// for the page's pointer events (Blink's `WebPointerProperties::force`, `PointerEvent.pressure`).
    /// A force click's Look Up is `quickLook(with:)`, which AppKit sends on its own.
    public override func pressureChange(with event: NSEvent) {
        sendGesture([Self.pressure(event.pressure, stage: event.stage)], event)
    }

    /// The kGesture pressure frame: pressure x 1e6 (0 to 1e6) and the stage (0 to 2).
    static func pressure(_ pressure: Float, stage: Int) -> Gesture {
        Gesture(type: .pressure, value: millionths(CGFloat(min(max(pressure, 0), 1))), stage: Int32(min(max(stage, 0), 2)))
    }

    /// `value` x 1e6 as the wire's integer, held to Int32's range; 0 for a value that is not finite.
    static func millionths(_ value: CGFloat) -> Int32 {
        guard value.isFinite else { return 0 }
        let scaled = (value * 1_000_000).rounded()
        return Int32(min(max(scaled, CGFloat(Int32.min)), CGFloat(Int32.max)))
    }

    /// One kGesture frame per entry of `gestures`, at `event`'s point, with its modifiers, time and
    /// the pressed buttons.
    private func sendGesture(_ gestures: [Gesture], _ event: NSEvent) {
        let point = pagePoint(event)
        let buttons = Self.pressedButtons()
        for gesture in gestures {
            _ = sink?(ChromiumHostFrame(.gesture, v: [point.x, point.y, gesture.type.rawValue, gesture.value, gesture.stage, buttons],
                                        flags: UInt64(event.modifierFlags.rawValue), t0: Self.nanoseconds(event.timestamp)))
        }
    }
}
#endif
