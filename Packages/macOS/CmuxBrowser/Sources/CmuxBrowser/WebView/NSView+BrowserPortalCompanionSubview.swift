public import AppKit
public import WebKit

extension NSView {
    /// Whether a visible WebKit-owned view other than `primaryWebView` (an inspector
    /// or media companion) is attached under this view.
    public func browserPortalHasVisibleWebKitCompanionSubview(for primaryWebView: WKWebView) -> Bool {
        var stack = subviews.filter { $0 !== primaryWebView }
        while let current = stack.popLast() {
            if current === primaryWebView || current.isDescendant(of: primaryWebView) {
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
