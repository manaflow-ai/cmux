public import AppKit
import ObjectiveC
public import WebKit

/// Keeps automated keyboard input from moving AppKit focus.
///
/// When Tab or Shift+Tab passes a page's last or first control, WebKit asks
/// its UI delegate to move focus out of the web view (`_webView:takeFocus:`),
/// and by default selects the window's next or previous key view. Keys a
/// REPL session sends to a tab must not do that: the window's first
/// responder is the user's (a terminal in the next pane, the omnibar), and
/// the tab may sit in a pane next to the user's work. While automated input
/// runs, focus that leaves the page stays in the web view, as in a headless
/// browser: the page has no focused element, and the next Tab focuses its
/// first control.
@MainActor
extension WKWebView {
    /// Runs automated input whose focus navigation must stay in this web view.
    public func withAutomationFocusContainment<T>(_ body: () async throws -> T) async rethrows -> T {
        automationFocusContainmentDepth += 1
        defer { automationFocusContainmentDepth -= 1 }
        return try await body()
    }

    /// Whether automated input is running in this web view.
    public var isContainingAutomationFocus: Bool {
        automationFocusContainmentDepth > 0
    }

    /// WebKit's `_webView:takeFocus:`: moves AppKit focus to the window's
    /// next (`forward`) or previous key view, as WebKit does without a
    /// delegate, but only when AppKit focus is in this web view, the window
    /// is one the user works in, and no automated input is running.
    ///
    /// Focus that is elsewhere (the user's terminal next to a driven page)
    /// cannot leave this web view: only keys sent to the web view directly
    /// (automation) get here then, and WebKit may handle such a key after the
    /// driver's round trip (a Tab queued behind Shift's flagsChanged), so
    /// the containment flag alone does not cover it. The REPL's off-screen
    /// render window keeps the web view first responder so the page stays
    /// focused.
    public func browserTakeFocus(forward: Bool) {
        guard !isContainingAutomationFocus, let window, !(window is BrowserOffscreenRenderPanel),
              isFirstResponderInside(window) else { return }
        if forward {
            // WebKit treats the web view as having no subviews: the next key
            // view after the last view of its own key view loop.
            window.selectKeyView(following: lastViewInKeyViewLoop)
        } else {
            window.selectKeyView(preceding: self)
        }
    }

    private func isFirstResponderInside(_ window: NSWindow) -> Bool {
        guard let view = window.firstResponder as? NSView else { return false }
        return view === self || view.isDescendant(of: self)
    }

    private var lastViewInKeyViewLoop: NSView {
        let selector = NSSelectorFromString("_findLastViewInKeyViewLoop")
        guard responds(to: selector), let view = perform(selector)?.takeUnretainedValue() as? NSView else { return self }
        return view
    }

    private var automationFocusContainmentDepth: Int {
        get { (objc_getAssociatedObject(self, Self.focusContainmentKey) as? NSNumber)?.intValue ?? 0 }
        set {
            objc_setAssociatedObject(self, Self.focusContainmentKey, NSNumber(value: max(0, newValue)), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    private static let focusContainmentKey: UnsafeRawPointer = {
        UnsafeRawPointer(Unmanaged.passUnretained(FocusContainmentKey.shared).toOpaque())
    }()
}

private final class FocusContainmentKey: NSObject, @unchecked Sendable {
    static let shared = FocusContainmentKey()
}
