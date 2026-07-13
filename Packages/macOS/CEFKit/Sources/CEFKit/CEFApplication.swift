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

    /// CefAppProtocol: whether the app is currently inside sendEvent;
    /// Chromium reads this to coordinate nested run loops.
    public func isHandlingSendEvent() -> Bool {
        handlingSendEvent
    }

    /// CefAppProtocol: set by Chromium around its own event dispatch.
    public func setHandlingSendEvent(_ value: Bool) {
        handlingSendEvent = value
    }

    /// Marks the handling-send-event window around AppKit event dispatch,
    /// as CefAppProtocol requires.
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
    /// e.g. the first right-click context menu in a browser.
    ///
    /// Fix: add the CefAppProtocol methods and conformance to NSApplication
    /// itself and swizzle sendEvent(_:) in place. The instance's class is
    /// never touched — isa-swizzling NSApp is NOT viable because SwiftUI
    /// registers KVO observers on it at startup, and swapping the class of
    /// an object with live observers corrupts KVO's own isa machinery
    /// (SIGSEGV in _NSKeyValueRetainedObservationInfoForObject on the next
    /// addObserver, reproduced with Chromium's first observer registration).
    /// There is exactly one NSApplication per process, so mutating the class
    /// is equivalent to mutating the instance.
    ///
    /// Returns true when NSApp conforms (already or after injection).
    @discardableResult
    static func ensureNSAppConformance() -> Bool {
        guard let app = NSApp else { return false }
        guard let crProto = objc_getProtocol("CrAppProtocol") else { return false }
        if app.conforms(to: crProto) { return true }

        let targetClass: AnyClass = NSApplication.self

        let isSel = NSSelectorFromString("isHandlingSendEvent")
        let isImp = imp_implementationWithBlock({ (_: AnyObject) -> Bool in
            injectedHandlingSendEvent
        } as @convention(block) (AnyObject) -> Bool)
        class_addMethod(targetClass, isSel, isImp, "c@:")

        let setSel = NSSelectorFromString("setHandlingSendEvent:")
        let setImp = imp_implementationWithBlock({ (_: AnyObject, value: Bool) in
            injectedHandlingSendEvent = value
        } as @convention(block) (AnyObject, Bool) -> Void)
        class_addMethod(targetClass, setSel, setImp, "v@:c")

        // sendEvent(_:) must bracket the original dispatch with the tracking
        // flag, exactly like CEFKitApplication.sendEvent above. Swizzle by
        // replacing the method's IMP and forwarding to the saved original.
        let sendSel = #selector(NSApplication.sendEvent(_:))
        typealias SendEventFn = @convention(c) (AnyObject, Selector, NSEvent) -> Void
        guard let sendMethod = class_getInstanceMethod(targetClass, sendSel) else { return false }
        let originalSend = unsafeBitCast(method_getImplementation(sendMethod), to: SendEventFn.self)
        let sendImp = imp_implementationWithBlock({ (receiver: AnyObject, event: NSEvent) in
            let previous = injectedHandlingSendEvent
            injectedHandlingSendEvent = true
            originalSend(receiver, sendSel, event)
            injectedHandlingSendEvent = previous
        } as @convention(block) (AnyObject, NSEvent) -> Void)
        method_setImplementation(sendMethod, sendImp)

        class_addProtocol(targetClass, crProto)
        if let controlProto = objc_getProtocol("CrAppControlProtocol") {
            class_addProtocol(targetClass, controlProto)
        }
        if let cefProto = objc_getProtocol("CefAppProtocol") {
            class_addProtocol(targetClass, cefProto)
        }
        return app.conforms(to: crProto)
    }
}
