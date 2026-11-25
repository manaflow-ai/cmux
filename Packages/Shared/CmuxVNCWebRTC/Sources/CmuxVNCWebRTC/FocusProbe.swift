import CoreGraphics
import Foundation
#if os(macOS)
import ApplicationServices
#endif

extension FocusSignalProducer {
    /// This Mac's focus: CGEvent's pointer, CGWindowList's frontmost window
    /// and the Accessibility API's caret (none on iOS).
    static func systemProbe() -> any FocusProbe {
        #if os(macOS)
        SystemFocusProbe()
        #else
        NoFocusProbe()
        #endif
    }
}

/// A source with no focus to report (iOS: no host there).
struct NoFocusProbe: FocusProbe {
    func pointer() -> CGPoint? { nil }
    func focusedWindow() -> FocusWindow? { nil }
    func caret() -> CGRect? { nil }
}

#if os(macOS)
/// The live probe. Every call is IPC (window server, the focused app's AX
/// server) and runs on the producer's queue, never the main thread. AX calls
/// wait at most ``axTimeout``. Never prompts for Accessibility: without the
/// grant the caret is nil and the rest still works.
// crash-allow: `lastPID` is read and written only under `lock`.
final class SystemFocusProbe: FocusProbe, @unchecked Sendable {
    /// The longest one AX request waits for a busy app (seconds).
    static let axTimeout: Float = 0.1
    /// Windows smaller than this (points) are not "the focused window" (tooltips, drag images).
    static let minimumWindowSide: CGFloat = 40

    private let lock = NSLock()
    /// The frontmost window's process, from the last window read.
    private var lastPID: pid_t?

    func pointer() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    /// The topmost normal (layer 0), visible, not tiny window on screen: the
    /// frontmost app's front window. Its number changes on an app or window switch.
    func focusedWindow() -> FocusWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let window = Self.frontmost(in: list)
        if let window { lock.withLock { lastPID = window.pid } }
        return window
    }

    static func frontmost(in list: [[String: Any]]) -> FocusWindow? {
        for info in list {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint64Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= minimumWindowSide, frame.height >= minimumWindowSide else { continue }
            return FocusWindow(id: number, frame: frame, pid: pid)
        }
        return nil
    }

    /// The insertion point of the frontmost app's focused element:
    /// `AXSelectedTextRange`'s end, through `AXBoundsForRange` (global
    /// display coordinates). An empty range many apps answer with nothing is
    /// asked as the character after it (its leading edge), then the one
    /// before (its trailing edge). cmux's own terminal answers through
    /// TerminalSurfaceView's accessibility (the cursor cell).
    func caret() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        guard let pid = lock.withLock({ lastPID }) ?? focusedWindow()?.pid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.axTimeout)
        guard let focused = Self.copy(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, Self.axTimeout)
        let role = Self.copy(element, kAXRoleAttribute) as? String
        let subrole = Self.copy(element, kAXSubroleAttribute) as? String
        // Where someone types a password is not sent: Follow uses the pointer, window and damage there.
        guard !Self.isSecureTextField(role: role, subrole: subrole) else { return nil }
        guard let selection = Self.copy(element, kAXSelectedTextRangeAttribute).flatMap({ Self.value($0, .cfRange, CFRange()) }) else { return nil }
        let end = selection.location + selection.length
        if let rect = Self.bounds(element, CFRange(location: end, length: 0)) { return rect }
        if let next = Self.bounds(element, CFRange(location: end, length: 1)) {
            return CGRect(x: next.minX, y: next.minY, width: 0, height: next.height)
        }
        if end > 0, let previous = Self.bounds(element, CFRange(location: end - 1, length: 1)) {
            return CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height)
        }
        return nil
    }

    /// A password field, by its Accessibility role or subrole (`AXSecureTextField`).
    static func isSecureTextField(role: String?, subrole: String?) -> Bool {
        let secure = "AXSecureTextField"
        return role == secure || subrole == secure
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    /// `AXBoundsForRange`; nil for an error or an empty answer at the origin (no position).
    private static func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
              let value, let rect = Self.value(value, .cgRect, CGRect.zero),
              rect.height > 0 || rect.width > 0, rect.minX.isFinite, rect.minY.isFinite else { return nil }
        return rect
    }

    private static func value<T>(_ object: CFTypeRef, _ type: AXValueType, _ initial: T) -> T? {
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(object, to: AXValue.self)
        guard AXValueGetType(axValue) == type else { return nil }
        var result = initial
        return AXValueGetValue(axValue, type, &result) ? result : nil
    }
}
#endif
