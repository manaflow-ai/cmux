#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its wire.
public import AppKit

/// The host page view's mouse input past clicks, moves and the wheel (task 054 of
/// plans/cmux-next/chrome-parity/p01-process.md): the middle and extra mouse buttons, the trackpad
/// pinch, smart zoom and Force Touch pressure. Chrome's page view sends each to its browser process
/// (content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm: `-otherMouseDown:`,
/// `-magnifyWithEvent:`, `-smartMagnifyWithEvent:`, `-pressureChangeWithEvent:`), on the same
/// ordered pipe as clicks and keys (`RenderWidgetHostNSViewHost` in
/// content/common/render_widget_host_ns_view.mojom: `RouteOrProcessMouseEvent`, `PinchEvent`,
/// `SmartMagnifyEvent`); here each is one wire frame (kMouse, kGesture in
/// ChromiumHost/src/chromium_host_wire.h) on the ordered input stream.
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

    /// The middle button and the buttons past it: the middle button (AppKit's 2) is the wire's 1. A
    /// back or forward press or release sends nothing yet (``wireButton(buttonNumber:)``); a drag with
    /// any button held is a pointer move, as Chrome's page view sends it.
    func otherMouse(_ event: NSEvent, phase: Int32) {
        guard let button = Self.wireButton(buttonNumber: event.buttonNumber) ?? (phase == 0 ? 0 : nil) else { return }
        mouse(event, phase: phase, button: button)
    }

    /// The wire's button for an AppKit button number (0 left, 1 right, 2 middle, as
    /// `ui/events/blink/web_input_event_builders_mac.mm` maps them to `WebPointerProperties::Button`);
    /// nil for the rest. Chrome sends the back and forward buttons (3 and 4) as `kBack` and `kForward`,
    /// but CEF's click has only left, middle and right, so they wait for the fork call that sends them
    /// (task 054b); sent now, the host could click them as another button.
    static func wireButton(buttonNumber: Int) -> Int32? {
        switch buttonNumber {
        case 0: 0
        case 1: 2
        case 2: 1
        default: nil
        }
    }

    /// The pressed buttons as the wire's bits: 1 left, 2 right, 4 middle, 8 back, 16 forward, which are
    /// `NSEvent.pressedMouseButtons`' bits and the DOM's `MouseEvent.buttons` both.
    static func pressedButtons(_ pressed: Int = NSEvent.pressedMouseButtons) -> Int32 {
        Int32(truncatingIfNeeded: pressed & 0x1f)
    }

    // MARK: Pinch and smart zoom

    /// A trackpad pinch: begin, one update per step, end, as `-magnifyWithEvent:` sends `PinchEvent`
    /// with a pinch begin, update or end gesture.
    public override func magnify(with event: NSEvent) {
        sendGesture(Self.pinch(phase: event.phase, magnification: event.magnification), event)
    }

    /// A two-finger double tap: Chrome's `SmartMagnifyEvent`, which zooms to the element under the pointer.
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
    /// for the page's pointer events (Blink's `WebPointerProperties::force`, `PointerEvent.pressure`),
    /// as Chrome's `-pressureChangeWithEvent:` sends a mouse event with force. The Look Up a force
    /// click starts (`-quickLookWithEvent:`, `LookUpDictionaryOverlayAtPoint`) is task 054b's.
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
        sendGesture(gestures, at: pagePoint(event), flags: UInt64(event.modifierFlags.rawValue), t0: Self.nanoseconds(event.timestamp))
    }

    private func sendGesture(_ gestures: [Gesture], at point: (x: Int32, y: Int32), flags: UInt64, t0: UInt64) {
        let buttons = Self.pressedButtons()
        for gesture in gestures {
            sendInput(ChromiumHostFrame(.gesture, v: [point.x, point.y, gesture.type.rawValue, gesture.value, gesture.stage, buttons],
                                        flags: flags, t0: t0))
        }
    }

    /// `debug.mouse` page `pinch` and `smart_magnify` (chromium-host-bench.py's gesture rows): the frames
    /// a whole trackpad pinch by `scale` (nil: a smart magnify) sends at `point` (top-left page points),
    /// through ``pinch(phase:magnification:)`` and the same send as a real one; AppKit has no public way
    /// to make a magnify event. Returns how many frames went out (none without a host).
    public func debugGesture(pinchScale scale: CGFloat?, at point: CGPoint) -> Int {
        guard sink != nil else { return 0 }
        let gestures = scale.map { Self.pinch(phase: [], magnification: $0 - 1) } ?? [Gesture(type: .smartMagnify)]
        sendGesture(gestures, at: (Int32(point.x.rounded(.down)), Int32(point.y.rounded(.down))), flags: 0,
                    t0: Self.nanoseconds(ProcessInfo.processInfo.systemUptime))
        return gestures.count
    }
}
#endif
