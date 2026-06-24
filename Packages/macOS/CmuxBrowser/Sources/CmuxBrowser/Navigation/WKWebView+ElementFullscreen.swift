public import WebKit
public import AppKit

/// HTML element-fullscreen state inspection for a web view.
///
/// cmux coordinates its own window chrome with WebKit's element-fullscreen
/// (a video or page region entering the browser's native fullscreen). These
/// accessors read `fullscreenState` and decide whether an external fullscreen
/// window is currently presenting the element, so cmux's window management can
/// stand down while WebKit owns the screen.
extension WKWebView {
    /// Whether HTML element-fullscreen is active or mid-transition (entering or
    /// exiting). Treats unknown future states as active so cmux defers to WebKit.
    public var cmuxIsElementFullscreenActiveOrTransitioning: Bool {
        switch fullscreenState {
        case .notInFullscreen:
            return false
        case .enteringFullscreen, .inFullscreen, .exitingFullscreen:
            return true
        @unknown default:
            return true
        }
    }

    /// Whether element-fullscreen is being presented by a window other than
    /// `expectedWindow` (an external fullscreen window WebKit created).
    ///
    /// Returns `false` when no element-fullscreen is active. When active with no
    /// `expectedWindow` given, returns `true` (the presenting window is, by
    /// definition, external to a caller that has none).
    public func cmuxIsManagedByExternalFullscreenWindow(relativeTo expectedWindow: NSWindow?) -> Bool {
        guard cmuxIsElementFullscreenActiveOrTransitioning else { return false }
        guard let expectedWindow else { return true }
        return window !== expectedWindow
    }
}
