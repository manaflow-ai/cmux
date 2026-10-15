public import AppKit
import ObjectiveC

/// CEF requires the app's `NSApplication` to conform to `CefAppProtocol`
/// (`isHandlingSendEvent` / `setHandlingSendEvent:`) and to report whether it
/// is inside `-sendEvent:`: Chromium's message pump and its menus defer work
/// while an event is being dispatched.
///
/// cmux uses a plain `NSApplication`, so this adds the conformance to the
/// running application's class at run time, once, when CEF starts (after the
/// shim is mapped, which registers the protocol). It also wraps the class's
/// current `-sendEvent:` (including cmux's own swizzle) so the flag is set
/// while an event is dispatched. Nothing changes in a session that never
/// starts Chromium.
@MainActor
public enum CEFApplicationSupport {
    /// True once `install()` succeeded in this process.
    public private(set) static var isInstalled = false
    /// The CefAppProtocol flag (main thread only; AppKit dispatches events there).
    nonisolated(unsafe) private static var handlingSendEvent = false

    /// Adds `CefAppProtocol` to the shared application's class. Idempotent.
    /// Returns false when the protocol is not registered (the shim is not
    /// loaded) or the runtime refuses the change.
    @discardableResult
    public static func install(application: NSApplication = .shared) -> Bool {
        if isInstalled { return true }
        guard let appClass = object_getClass(application) else { return false }
        guard let proto = objc_getProtocol("CefAppProtocol") else { return false }

        let getSelector = NSSelectorFromString("isHandlingSendEvent")
        let setSelector = NSSelectorFromString("setHandlingSendEvent:")
        if !application.responds(to: getSelector) {
            let getter: @convention(block) (AnyObject) -> ObjCBool = { _ in ObjCBool(handlingSendEvent) }
            class_addMethod(appClass, getSelector, imp_implementationWithBlock(getter), "c@:")
        }
        if !application.responds(to: setSelector) {
            let setter: @convention(block) (AnyObject, ObjCBool) -> Void = { _, value in handlingSendEvent = value.boolValue }
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
    private static func wrapSendEvent(_ appClass: AnyClass) {
        typealias SendEvent = @convention(c) (AnyObject, Selector, NSEvent) -> Void
        let selector = #selector(NSApplication.sendEvent(_:))
        guard let method = class_getInstanceMethod(appClass, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: SendEvent.self)
        let wrapped: @convention(block) (AnyObject, NSEvent) -> Void = { app, event in
            let outer = handlingSendEvent
            handlingSendEvent = true
            defer { handlingSendEvent = outer }
            original(app, selector, event)
        }
        let types = method_getTypeEncoding(method)
        class_replaceMethod(appClass, selector, imp_implementationWithBlock(wrapped), types)
    }
}
