// The hosted widgets' ops (plans/cmux-next/chromium-host-ops.json optional_exports, task 066): what
// cmux tells the Chromium host about a widget it shows (``ChromiumHostWidgetHost``).

/// The shim's hosted-widget functions (``CEFShimLibrary/widgets``). Each is nil without the export:
/// in process, and with a host whose hello does not list it (fork task 173 not in its shim).
/// Immutable C function pointers, part of the library that crosses from the loading thread.
nonisolated struct CEFShimWidgetOps {
    /// A widget cmux places moved or resized: widget, bottom left x, y (AppKit screen points), width,
    /// height, backing scale x 1000.
    let setGeometry: (@convention(c) (Int32, Int32, Int32, Int32, Int32, Int32) -> Void)?
    /// The person closed the widget in cmux: widget.
    let dismiss: (@convention(c) (Int32) -> Void)?
    /// Input to a widget: widget, then a `ChromiumHostFrame`'s kind, v0...v5, flags, time (ns), ch, unmod.
    let sendInput: (@convention(c) (Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int64, Int64, Int32, Int32) -> Void)?

    /// The host's shim has every widget op: cmux can place, close and drive its widgets.
    var isComplete: Bool { setGeometry != nil && dismiss != nil && sendInput != nil }
}

/// ``ChromiumHostWidgetWire`` on the host's remote shim: each call is one op on the host's wire
/// (geometry coalesces per widget in the client, input goes on the input channel), as
/// `NativeWidgetNSWindowBridge` sends its window's bounds and events to the browser process in Chrome
/// (components/remote_cocoa/app_shim/native_widget_ns_window_bridge.mm).
final class CEFShimWidgetWire: ChromiumHostWidgetWire {
    private let ops: CEFShimWidgetOps

    init(ops: CEFShimWidgetOps) {
        self.ops = ops
    }

    func widget(_ widget: ChromiumHostWidgetID, movedTo geometry: ChromiumHostGeometry) {
        ops.setGeometry?(widget.rawValue, geometry.screenX, geometry.screenY, geometry.width, geometry.height, geometry.scaleMilli)
    }

    func dismiss(_ widget: ChromiumHostWidgetID) {
        ops.dismiss?(widget.rawValue)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    func widget(_ widget: ChromiumHostWidgetID, input frame: ChromiumHostFrame) {
        let v = frame.v
        ops.sendInput?(widget.rawValue, Int32(bitPattern: frame.rawKind), v[0], v[1], v[2], v[3], v[4], v[5],
                       Int64(bitPattern: frame.flags), Int64(bitPattern: frame.t0), Int32(frame.ch), Int32(frame.unmod))
    }
    #endif
}
