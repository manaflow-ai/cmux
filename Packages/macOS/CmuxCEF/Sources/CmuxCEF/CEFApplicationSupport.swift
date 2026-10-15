import AppKit
import ObjectiveC

/// Chromium's application protocols (base/message_loop/message_pump_apple.h,
/// include/cef_application_mac.h), declared under their Objective-C names.
/// The Objective-C runtime keeps the first protocol registered under a name
/// and remaps later references to it. These are registered when the app
/// launches, long before the shim is mapped, so the shim's
/// `@protocol(CefAppProtocol)` resolves to this declaration (the same
/// approach as cmux Next's CmuxApplication).
@objc(CrAppProtocol) protocol ChromiumAppProtocol: NSObjectProtocol {
    @objc(isHandlingSendEvent) func isHandlingSendEvent() -> Bool
}

@objc(CrAppControlProtocol) protocol ChromiumAppControlProtocol: ChromiumAppProtocol {
    @objc(setHandlingSendEvent:) func setHandlingSendEvent(_ handlingSendEvent: Bool)
}

@objc(CefAppProtocol) protocol CEFAppProtocol: ChromiumAppControlProtocol {}

/// CEF requires the app's `NSApplication` to conform to `CefAppProtocol`
/// (`isHandlingSendEvent` / `setHandlingSendEvent:`) and to report whether it
/// is inside `-sendEvent:`: Chromium's message pump and its menus defer work
/// while an event is being dispatched.
///
/// cmux uses a plain `NSApplication`, so `install` adds the conformance to the
/// running application's class at run time, once, when CEF starts. It also wraps the class's
/// current `-sendEvent:` (including cmux's own swizzle) so the flag is set
/// while an event is dispatched. Nothing changes in a session that never
/// starts Chromium. The runtime owns the one instance; AppKit calls the added
/// methods on the main thread.
final class CEFApplicationSupport {
    /// True once `install` succeeded.
    private(set) var isInstalled = false
    /// The CefAppProtocol flag.
    private var handlingSendEvent = false

    /// Adds `CefAppProtocol` to `application`'s class. Idempotent. Returns
    /// false when the protocol is not registered (the shim is not loaded) or
    /// the runtime refuses the change.
    @MainActor
    @discardableResult
    func install(application: NSApplication) -> Bool {
        if isInstalled { return true }
        guard let appClass = object_getClass(application) else { return false }
        let proto: Protocol = CEFAppProtocol.self

        let getSelector = NSSelectorFromString("isHandlingSendEvent")
        let setSelector = NSSelectorFromString("setHandlingSendEvent:")
        if !application.responds(to: getSelector) {
            let getter: @convention(block) (AnyObject) -> ObjCBool = { [unowned self] _ in
                ObjCBool(self.handlingSendEvent)
            }
            class_addMethod(appClass, getSelector, imp_implementationWithBlock(getter), "c@:")
        }
        if !application.responds(to: setSelector) {
            let setter: @convention(block) (AnyObject, ObjCBool) -> Void = { [unowned self] _, value in
                self.handlingSendEvent = value.boolValue
            }
            class_addMethod(appClass, setSelector, imp_implementationWithBlock(setter), "v@:c")
        }
        if !class_conformsToProtocol(appClass, proto) {
            class_addProtocol(appClass, proto)
        }
        wrapSendEvent(appClass)
        isInstalled = application.conforms(to: proto)
        return isInstalled
    }

    /// Wraps the current `-sendEvent:` so `isHandlingSendEvent` is true while
    /// it runs (restoring the outer value for nested dispatch).
    private func wrapSendEvent(_ appClass: AnyClass) {
        typealias SendEvent = @convention(c) (AnyObject, Selector, NSEvent) -> Void
        let selector = #selector(NSApplication.sendEvent(_:))
        guard let method = class_getInstanceMethod(appClass, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: SendEvent.self)
        let wrapped: @convention(block) (AnyObject, NSEvent) -> Void = { [unowned self] app, event in
            let outer = self.handlingSendEvent
            self.handlingSendEvent = true
            defer { self.handlingSendEvent = outer }
            original(app, selector, event)
        }
        class_replaceMethod(appClass, selector, imp_implementationWithBlock(wrapped), method_getTypeEncoding(method))
    }
}
