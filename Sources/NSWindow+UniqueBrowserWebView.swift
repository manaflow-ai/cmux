import AppKit

extension NSWindow {
    /// The only `CmuxWebView` under `root`, or `nil` when there are none or
    /// more than one.
    static func cmuxUniqueBrowserWebView(in root: NSView) -> CmuxWebView? {
        var stack: [NSView] = [root]
        var found: CmuxWebView?
        while let current = stack.popLast() {
            if let webView = current as? CmuxWebView {
                if found == nil {
                    found = webView
                } else if found !== webView {
                    return nil
                }
            }
            stack.append(contentsOf: current.subviews)
        }
        return found
    }
}
