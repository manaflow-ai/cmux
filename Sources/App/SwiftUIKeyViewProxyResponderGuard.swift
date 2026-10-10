import AppKit
import ObjectiveC

/// Keeps responder-chain walks from aborting on a SwiftUI `KeyViewProxy` that outlived its host.
///
/// SwiftUI inserts a private `KeyViewProxy` subview into an `NSHostingView` for each focusable
/// element. Its `nextResponder` getter returns `focusBridge.host`, an unowned reference to that
/// hosting view. When the hosting view is freed while anything still holds the proxy, every
/// `nextResponder` read traps with "Attempted to read an unowned reference but object was already
/// deallocated". cmux's shortcut routing, AppKit's event routing and SwiftUI's own first-responder
/// observer all walk the chain, so the crash surfaces from many call sites.
///
/// While the proxy is attached, its host is its superview and that is the value `nextResponder`
/// returns. A freed host clears its subviews' `superview`, so forwarding from a detached proxy
/// is unsafe. The guard conservatively ends the chain while detached, including during a
/// temporary detach from a still-live host, and leaves attached proxies untouched.
///
/// Focus recovery belongs to window event routing. This getter must not change first responder
/// while AppKit or SwiftUI is traversing the responder chain.
enum SwiftUIKeyViewProxyResponderGuard {
    private static let proxyClassName = "SwiftUI.KeyViewProxy"

    /// Installs the guard once. Does nothing when SwiftUI no longer ships the class.
    static func install() {
        _ = didInstall
    }

    private static let didInstall: Void = {
        guard let proxyClass = NSClassFromString(proxyClassName) else {
            return
        }
        let selector = #selector(getter: NSResponder.nextResponder)
        // Resolves to the inherited getter if SwiftUI ever stops overriding it, and
        // class_replaceMethod then adds the override on the proxy class alone.
        guard let method = class_getInstanceMethod(proxyClass, selector),
              let types = method_getTypeEncoding(method) else {
            return
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> NSResponder?
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)

        let guarded: @convention(block) (AnyObject) -> NSResponder? = { proxy in
            if Thread.isMainThread, let view = proxy as? NSView {
                let isDetached = MainActor.assumeIsolated { view.superview == nil }
                if isDetached {
                    return nil
                }
            }
            return original(proxy, selector)
        }
        class_replaceMethod(proxyClass, selector, imp_implementationWithBlock(guarded), types)
    }()
}
