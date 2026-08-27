import AppKit

/// Describes how a browser web view is hosted while an automation screenshot runs.
enum BrowserScreenshotPresentation: Equatable {
    /// A view owned by a user-visible pane and left in its existing host.
    case onscreen
    /// A hidden view temporarily attached to the offscreen render host.
    case offscreen

    /// Whether the web view needs the temporary offscreen render host.
    var usesOffscreenRenderHost: Bool {
        self == .offscreen
    }

    /// Whether this attempt waits for WebKit animation-frame callbacks.
    ///
    /// - Parameter isRetry: Whether this is a retry after pixel disagreement.
    /// - Returns: `true` when the attempt should perform double-rAF synchronization.
    func waitsForAnimationFrame(isRetry: Bool) -> Bool {
        isRetry || self == .onscreen
    }

    /// Resolves the presentation without treating window occlusion as ownership.
    ///
    /// - Parameters:
    ///   - isVisibleInUI: Whether the browser pane is the visible UI owner.
    ///   - isAttachedToWindow: Whether the web view remains attached to a window.
    ///   - isHiddenOrHasHiddenAncestor: Whether AppKit hides the view hierarchy.
    ///   - boundsSize: Current web-view bounds.
    /// - Returns: The host policy for the capture lease.
    static func resolve(
        isVisibleInUI: Bool,
        isAttachedToWindow: Bool,
        isHiddenOrHasHiddenAncestor: Bool,
        boundsSize: NSSize
    ) -> Self {
        guard isVisibleInUI,
              isAttachedToWindow,
              !isHiddenOrHasHiddenAncestor,
              boundsSize.width > 1,
              boundsSize.height > 1 else {
            return .offscreen
        }
        return .onscreen
    }
}
