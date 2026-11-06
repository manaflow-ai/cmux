// SPDX-License-Identifier: GPL-3.0-or-later
@preconcurrency import ApplicationServices
import Foundation

/// An accessibility element that may cross threads. AXUIElement is an
/// immutable CF reference and the AX client API may be called from any thread.
struct AXElement: @unchecked Sendable, Hashable {
    let raw: AXUIElement

    init(_ raw: AXUIElement) { self.raw = raw }
    init(pid: pid_t) { raw = AXUIElementCreateApplication(pid) }

    static func == (lhs: AXElement, rhs: AXElement) -> Bool { CFEqual(lhs.raw, rhs.raw) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(raw)) }

    var pid: pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(raw, &pid)
        return pid
    }

    func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw, name as CFString, &value) == .success else { return nil }
        return value
    }

    func element(_ name: String) -> AXElement? {
        guard let value = attribute(name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(unsafeBitCast(value, to: AXUIElement.self))
    }

    func elements(_ name: String) -> [AXElement] {
        guard let value = attribute(name) as? [AXUIElement] else { return [] }
        return value.map(AXElement.init)
    }

    func string(_ name: String) -> String? { attribute(name) as? String }

    var frame: CGRect? {
        guard let position = point(attribute(kAXPositionAttribute)),
              let size = size(attribute(kAXSizeAttribute)) else { return nil }
        return CGRect(origin: position, size: size)
    }

    func setMessagingTimeout(_ seconds: Float) { AXUIElementSetMessagingTimeout(raw, seconds) }

    @discardableResult
    func perform(_ action: String) -> AXError { AXUIElementPerformAction(raw, action as CFString) }

    @discardableResult
    func set(_ name: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(raw, name as CFString, value)
    }

    func isSettable(_ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(raw, name as CFString, &settable) == .success && settable.boolValue
    }

    var actionNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(raw, &names) == .success, let names = names as? [String] else { return [] }
        return names
    }

    /// The window server id of an AXWindow (private but stable since 10.5;
    /// resolved at run time so a missing symbol degrades to frame matching).
    var windowID: CGWindowID? {
        guard let getWindow = AXPrivate.shared.getWindow else { return nil }
        var id: CGWindowID = 0
        guard getWindow(raw, &id) == .success, id != 0 else { return nil }
        return id
    }
}

func point(_ value: CFTypeRef?) -> CGPoint? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let ax = unsafeBitCast(value, to: AXValue.self)
    var point = CGPoint.zero
    return AXValueGetValue(ax, .cgPoint, &point) ? point : nil
}

func size(_ value: CFTypeRef?) -> CGSize? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let ax = unsafeBitCast(value, to: AXValue.self)
    var size = CGSize.zero
    return AXValueGetValue(ax, .cgSize, &size) ? size : nil
}

/// Private AX entry points looked up once.
final class AXPrivate: @unchecked Sendable {
    typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    static let shared = AXPrivate()
    let getWindow: GetWindow?

    private init() {
        let handle = dlopen(nil, RTLD_NOW)
        if let symbol = dlsym(handle, "_AXUIElementGetWindow") {
            getWindow = unsafeBitCast(symbol, to: GetWindow.self)
        } else {
            getWindow = nil
        }
    }
}
