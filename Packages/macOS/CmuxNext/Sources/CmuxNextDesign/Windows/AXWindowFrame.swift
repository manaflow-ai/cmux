#if DEBUG || CMUX_BENCH_HOOKS
public import ApplicationServices
import CmuxNextCompat

/// One window of a process as the Accessibility API sees it, for `debug.window.ax_set_frame` (the app moves its
/// own window the way Rectangle does). Every AX call sends a Mach message to the window's app and waits for the
/// answer (up to the messaging timeout), through the AX seams: make and use it on a system lane, never on the
/// main thread, which must be free to answer when the app is this one.
public nonisolated struct AXWindowFrame: @unchecked Sendable { // crash-allow: immutable CF references; the AX API takes them on any thread
    private let window: AXUIElement
    /// The app's AX windows (role, subrole, frame), as it listed them when the window was found.
    public let windows: [String]
    /// The frame of the app's AX focused window then, nil without one.
    public let focusedFrame: String?

    /// The window of process `pid` whose AX frame (top-left origin of the primary display) is nearest `frame`;
    /// nil when the app lists no window.
    public init?(pid: pid_t, nearest frame: CGRect) {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        // SAFETY: the call writes one +1 CFTypeRef (or nil) into the local `value`, live for the call.
        guard unsafe blockingAXCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement],
              let window = windows.min(by: { Self.distance(Self.frame(of: $0), frame) < Self.distance(Self.frame(of: $1), frame) })
        else { return nil }
        var focused: CFTypeRef?
        self.window = window
        self.windows = windows.map { "\(Self.string($0, kAXRoleAttribute)) \(Self.string($0, kAXSubroleAttribute)) \(Self.frame(of: $0))" }
        // SAFETY: as above, into the local `focused`.
        focusedFrame = unsafe blockingAXCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success
            ? focused.flatMap(Self.element).map { "\(Self.frame(of: $0))" } : nil
    }

    /// Sets the window's AX position (`attribute` "position") or size (any other) from `frame`.
    public func set(_ attribute: String, from frame: CGRect) -> AXError {
        if attribute == "position" {
            var point = frame.origin
            // SAFETY: AXValueCreate copies one CGPoint (the type .cgPoint names) from the local `point`.
            guard let value = unsafe AXValueCreate(.cgPoint, &point) else { return .failure }
            return blockingAXSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
        var size = frame.size
        // SAFETY: AXValueCreate copies one CGSize (the type .cgSize names) from the local `size`.
        guard let value = unsafe AXValueCreate(.cgSize, &size) else { return .failure }
        return blockingAXSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        // SAFETY: the call writes one +1 CFTypeRef (or nil) into the local `value`, live for the call.
        guard unsafe blockingAXCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "-" }
        return (value as? String) ?? "-"
    }

    private static func frame(of element: AXUIElement) -> CGRect {
        var position = CGPoint.zero, size = CGSize.zero
        var value: CFTypeRef?
        // SAFETY: each copy writes one CFTypeRef (or nil) into the local `value`; each AXValueGetValue writes the one
        // CGPoint or CGSize its type names into the local of that type. All are live for the calls.
        if unsafe blockingAXCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
           let value = value.flatMap(axValue) {
            unsafe AXValueGetValue(value, .cgPoint, &position)
        }
        if unsafe blockingAXCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
           let value = value.flatMap(axValue) {
            unsafe AXValueGetValue(value, .cgSize, &size)
        }
        return CGRect(origin: position, size: size)
    }

    /// The value as an AXUIElement when its CoreFoundation type is one (nil otherwise).
    private static func element(_ value: CFTypeRef) -> AXUIElement? {
        // SAFETY: the type ID check proves `value` is a AXUIElement.
        CFGetTypeID(value) == AXUIElementGetTypeID() ? unsafe unsafeDowncast(value, to: AXUIElement.self) : nil
    }

    /// The value as an AXValue when its CoreFoundation type is one (nil otherwise).
    private static func axValue(_ value: CFTypeRef) -> AXValue? {
        // SAFETY: the type ID check proves `value` is a AXValue.
        CFGetTypeID(value) == AXValueGetTypeID() ? unsafe unsafeDowncast(value, to: AXValue.self) : nil
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}
#endif
