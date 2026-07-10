import AppKit
import CCEF

/// NSApplication subclass required by CEF on macOS. libcef verifies at
/// runtime that NSApp conforms to CefAppProtocol so it can coordinate event
/// dispatch with Chromium's internal message pump. Use as NSPrincipalClass
/// (the class is exposed to ObjC as "CEFKitApplication") or instantiate
/// manually before calling CEFApp.initialize.
@objc(CEFKitApplication)
open class CEFKitApplication: NSApplication, CefAppProtocol {
    private var handlingSendEvent = false

    public func isHandlingSendEvent() -> Bool {
        handlingSendEvent
    }

    public func setHandlingSendEvent(_ value: Bool) {
        handlingSendEvent = value
    }

    open override func sendEvent(_ event: NSEvent) {
        let previous = handlingSendEvent
        handlingSendEvent = true
        defer { handlingSendEvent = previous }
        super.sendEvent(event)
    }
}
