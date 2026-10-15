public import AppKit

/// Where the engine creates the next DevTools.
public enum BrowserDevToolsPlacement {
    /// As a child of `parent`, sized to `size`; cmux moves `parent` between the pane and the
    /// DevTools window, so the same DevTools follow every dock change.
    case inView(NSView, size: CGSize)
    /// In the engine's own top-level window at `frame`, in Chromium screen coordinates (origin
    /// at the top-left of the primary screen). `.zero` lets the engine choose.
    case ownWindow(CGRect)
}
