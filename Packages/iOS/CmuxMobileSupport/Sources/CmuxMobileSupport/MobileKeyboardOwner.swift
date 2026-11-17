#if canImport(UIKit)
public import UIKit

/// Whether anything in the app can own a software keyboard: UIKit shows one
/// only for a first responder that takes text (a text field or view, a
/// terminal surface, anything with an input view). No such responder means
/// no keyboard of this app is on screen, whatever the last keyboard
/// notification said (``MobileKeyboardFrameTracker/dropKeyboardWithoutOwner()``).
@MainActor
public enum MobileKeyboardOwner {
    /// The app's first responder, through the responder chain (UIKit has no
    /// public accessor): an action sent to no target reaches it first, and it
    /// writes itself into the lookup it was sent from.
    public static var firstResponder: UIResponder? {
        let lookup = FirstResponderLookup()
        UIApplication.shared.sendAction(#selector(UIResponder.cmuxMobileReportFirstResponder(_:)), to: nil, from: lookup, for: nil)
        guard let responder = lookup.found, responder.isFirstResponder else { return nil }
        return responder
    }

    /// A first responder that takes text is there.
    public static var isPresent: Bool {
        guard let responder = firstResponder else { return false }
        return takesText(responder)
    }

    /// Whether `responder`, as first responder, brings up a keyboard (or an
    /// input view in its place).
    public static func takesText(_ responder: UIResponder) -> Bool {
        responder is UIKeyInput || responder.inputView != nil
    }
}

/// One first-responder lookup's answer (``MobileKeyboardOwner/firstResponder``).
@MainActor
final class FirstResponderLookup: NSObject {
    weak var found: UIResponder?
}

extension UIResponder {
    @objc fileprivate func cmuxMobileReportFirstResponder(_ sender: Any?) {
        (sender as? FirstResponderLookup)?.found = self
    }
}
#endif
