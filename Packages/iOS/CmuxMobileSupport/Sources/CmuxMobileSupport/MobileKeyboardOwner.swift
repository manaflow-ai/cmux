#if canImport(UIKit)
public import UIKit

/// Whether anything in the app can own a software keyboard: UIKit shows one
/// only for a first responder that takes text (a text field or view, a
/// terminal surface, anything with an input view). No such responder means
/// no keyboard of this app is on screen, whatever the last keyboard
/// notification said (``MobileKeyboardFrameTracker/dropKeyboardWithoutOwner()``).
@MainActor
public enum MobileKeyboardOwner {
    /// The app's first responder. UIKit has no public accessor: an action
    /// sent to no target reaches the key window's first responder, which
    /// writes itself into the lookup it was sent from. With no key window
    /// (a scene going to or coming from the background), the scene windows'
    /// views are searched instead. Read only while a keyboard is on record as
    /// shown, so the search runs at most once per foreground or page appear.
    public static var firstResponder: UIResponder? {
        let lookup = FirstResponderLookup()
        UIApplication.shared.sendAction(#selector(UIResponder.cmuxMobileReportFirstResponder(_:)), to: nil, from: lookup, for: nil)
        if let responder = lookup.found, responder.isFirstResponder { return responder }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return firstResponder(in: windows)
    }

    /// A first responder that takes text is there.
    public static var isPresent: Bool {
        guard let responder = firstResponder else { return false }
        return takesText(responder)
    }

    /// The first responder among `windows`' views, if one is there.
    public static func firstResponder(in windows: [UIWindow]) -> UIResponder? {
        for window in windows {
            if let found = firstResponder(under: window) { return found }
        }
        return nil
    }

    /// A first responder that takes text is among `windows`' views.
    public static func isPresent(in windows: [UIWindow]) -> Bool {
        guard let responder = firstResponder(in: windows) else { return false }
        return takesText(responder)
    }

    /// Whether `responder`, as first responder, brings up a keyboard (or an
    /// input view in its place).
    public static func takesText(_ responder: UIResponder) -> Bool {
        responder is UIKeyInput || responder.inputView != nil
    }

    private static func firstResponder(under view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let found = firstResponder(under: subview) { return found }
        }
        return nil
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
