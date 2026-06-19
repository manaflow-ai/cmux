public import AppKit
public import WebKit

extension NSResponder {
    /// Walks this responder, its view/superview chain, any text-view delegate
    /// view, and the responder chain to find the `WKWebView` that owns it.
    ///
    /// Used by the command palette to map a focused responder back to its
    /// hosting web view when restoring focus after the palette dismisses.
    @MainActor
    public var commandPaletteOwningWebView: WKWebView? {
        if let webView = self as? WKWebView {
            return webView
        }

        if let view = self as? NSView {
            var current: NSView? = view
            while let candidate = current {
                if let webView = candidate as? WKWebView {
                    return webView
                }
                current = candidate.superview
            }
        }

        if let textView = self as? NSTextView,
           let delegateView = textView.delegate as? NSView,
           let webView = delegateView.commandPaletteOwningWebView {
            return webView
        }

        var currentResponder = nextResponder
        while let next = currentResponder {
            if let webView = next.commandPaletteOwningWebView {
                return webView
            }
            currentResponder = next.nextResponder
        }

        return nil
    }
}
