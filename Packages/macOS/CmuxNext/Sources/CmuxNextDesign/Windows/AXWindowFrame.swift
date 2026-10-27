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
        guard blockingAXCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement],
              let window = windows.min(by: { Self.distance(Self.frame(of: $0), frame) < Self.distance(Self.frame(of: $1), frame) })
        else { return nil }
        var focused: CFTypeRef?
        self.window = window
        self.windows = windows.map { "\(Self.string($0, kAXRoleAttribute)) \(Self.string($0, kAXSubroleAttribute)) \(Self.frame(of: $0))" }
        focusedFrame = blockingAXCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success
            ? focused.flatMap(Self.element).map { "\(Self.frame(of: $0))" } : nil
    }

    /// Sets the window's AX position (`attribute` "position") or size (any other) from `frame`.
    public func set(_ attribute: String, from frame: CGRect) -> AXError {
        if attribute == "position" {
            var point = frame.origin
            guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
            return blockingAXSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
        var size = frame.size
        guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
        return blockingAXSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard blockingAXCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "-" }
        return (value as? String) ?? "-"
    }

    private static func frame(of element: AXUIElement) -> CGRect {
        var position = CGPoint.zero, size = CGSize.zero
        var value: CFTypeRef?
        if blockingAXCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success, let value = value.flatMap(axValue) {
            AXValueGetValue(value, .cgPoint, &position)
        }
        if blockingAXCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success, let value = value.flatMap(axValue) {
            AXValueGetValue(value, .cgSize, &size)
        }
        return CGRect(origin: position, size: size)
    }

    /// The value as an AXUIElement when its CoreFoundation type is one (nil otherwise).
    private static func element(_ value: CFTypeRef) -> AXUIElement? {
        CFGetTypeID(value) == AXUIElementGetTypeID() ? unsafeDowncast(value, to: AXUIElement.self) : nil
    }

    /// The value as an AXValue when its CoreFoundation type is one (nil otherwise).
    private static func axValue(_ value: CFTypeRef) -> AXValue? {
        CFGetTypeID(value) == AXValueGetTypeID() ? unsafeDowncast(value, to: AXValue.self) : nil
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}
#endif
