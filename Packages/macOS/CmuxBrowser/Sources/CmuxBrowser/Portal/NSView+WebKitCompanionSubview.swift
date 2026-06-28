public import AppKit
public import WebKit

extension NSView {
    /// Whether this host view contains a visible WebKit-managed companion subview
    /// alongside `primaryWebView`, the signature of an attached/docked Web
    /// Inspector that splits the hosted page into sibling `WK*` views. Walks the
    /// subview tree (skipping descendants of `primaryWebView` itself, and hidden
    /// or transparent branches) and reports true on the first `WK`-prefixed view
    /// larger than a hairline in both dimensions.
    ///
    /// Used by the browser portal/panel to preserve WebKit's split frame instead
    /// of resetting a plain web view's frame back to the container bounds.
    public func hasWebKitCompanionSubview(primaryWebView: WKWebView) -> Bool {
        var stack = subviews.filter { $0 !== primaryWebView }
        while let current = stack.popLast() {
            if current.isDescendant(of: primaryWebView) {
                continue
            }
            if current.isHidden || current.alphaValue <= 0 {
                continue
            }
            if String(describing: type(of: current)).contains("WK") {
                let width = max(current.frame.width, current.bounds.width)
                let height = max(current.frame.height, current.bounds.height)
                if width > 1, height > 1 {
                    return true
                }
                continue
            }
            stack.append(contentsOf: current.subviews)
        }
        return false
    }
}
