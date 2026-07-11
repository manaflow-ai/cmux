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

/// Backing store for the injected conformance below. There is exactly one
/// NSApplication per process and sendEvent is main-thread confined.
private var injectedHandlingSendEvent = false

extension CEFKitApplication {
    /// Makes the live NSApp satisfy libcef's CrAppProtocol check when the
    /// host did not install CEFKitApplication. SwiftUI apps ignore
    /// NSPrincipalClass and instantiate a plain NSApplication, so Chromium
    /// SIGTRAPs (DCHECK [NSApp conformsToProtocol:@protocol(CrAppProtocol)],
    /// message_pump_apple.mm) the first time it enters a nested run loop —
    /// e.g. the first right-click context menu in a browser. Fix: register a
    /// runtime subclass of NSApp's current class (whatever it is, including
    /// KVO-notifying classes) that implements the CefAppProtocol event
    /// tracking, and swap the instance's class. Layout-safe because the
    /// subclass adds no ivars; the tracking flag lives in a file-private
    /// global.
    ///
    /// Returns true when NSApp conforms (already or after injection).
    @discardableResult
    static func ensureNSAppConformance() -> Bool {
        guard let app = NSApp, let currentClass = object_getClass(app) else { return false }
        guard let crProto = objc_getProtocol("CrAppProtocol") else { return false }
        if class_conformsToProtocol(currentClass, crProto) { return true }

        let injectedName = "CEFKitInjected_\(NSStringFromClass(currentClass))"
        if let existing = NSClassFromString(injectedName) {
            object_setClass(app, existing)
            return true
        }
        guard let injected = objc_allocateClassPair(currentClass, injectedName, 0) else { return false }

        let isSel = NSSelectorFromString("isHandlingSendEvent")
        let isImp = imp_implementationWithBlock({ (_: AnyObject) -> Bool in
            injectedHandlingSendEvent
        } as @convention(block) (AnyObject) -> Bool)
        class_addMethod(injected, isSel, isImp, "c@:")

        let setSel = NSSelectorFromString("setHandlingSendEvent:")
        let setImp = imp_implementationWithBlock({ (_: AnyObject, value: Bool) in
            injectedHandlingSendEvent = value
        } as @convention(block) (AnyObject, Bool) -> Void)
        class_addMethod(injected, setSel, setImp, "v@:c")

        // sendEvent: must bracket the superclass dispatch with the tracking
        // flag, exactly like CEFKitApplication.sendEvent above. The
        // superclass IMP is resolved from the pre-injection class, which is
        // what `super` would mean inside the injected subclass.
        let sendSel = #selector(NSApplication.sendEvent(_:))
        typealias SendEventFn = @convention(c) (AnyObject, Selector, NSEvent) -> Void
        guard let superImpRaw = class_getMethodImplementation(currentClass, sendSel) else {
            objc_disposeClassPair(injected)
            return false
        }
        let superSend = unsafeBitCast(superImpRaw, to: SendEventFn.self)
        let sendImp = imp_implementationWithBlock({ (receiver: AnyObject, event: NSEvent) in
            let previous = injectedHandlingSendEvent
            injectedHandlingSendEvent = true
            superSend(receiver, sendSel, event)
            injectedHandlingSendEvent = previous
        } as @convention(block) (AnyObject, NSEvent) -> Void)
        class_addMethod(injected, sendSel, sendImp, "v@:@")

        class_addProtocol(injected, crProto)
        if let controlProto = objc_getProtocol("CrAppControlProtocol") {
            class_addProtocol(injected, controlProto)
        }
        if let cefProto = objc_getProtocol("CefAppProtocol") {
            class_addProtocol(injected, cefProto)
        }
        objc_registerClassPair(injected)
        object_setClass(app, injected)
        return true
    }
}
