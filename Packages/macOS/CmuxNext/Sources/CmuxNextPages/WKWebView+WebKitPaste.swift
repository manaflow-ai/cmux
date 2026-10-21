public import WebKit
import ObjectiveC.runtime

public extension WKWebView {
    /// WebKit's own `paste:` (Cmd-V, Edit > Paste), for a subclass whose `paste(_:)` sees the paste
    /// first. WKWebView implements the action but declares it in no header Swift sees, so the
    /// subclass can't call `super`: this runs WKWebView's implementation on the view. It does
    /// nothing on a WebKit without one, as the responder chain would have.
    func webKitPaste(_ sender: Any?) {
        let selector = #selector(NSText.paste(_:))
        guard WKWebView.instancesRespond(to: selector), let implementation = class_getMethodImplementation(WKWebView.self, selector) else { return }
        typealias Paste = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        unsafeBitCast(implementation, to: Paste.self)(self, selector, sender.map { $0 as AnyObject })
    }
}
