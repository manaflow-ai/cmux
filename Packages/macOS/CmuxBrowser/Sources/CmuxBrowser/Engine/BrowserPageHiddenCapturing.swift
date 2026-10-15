import Foundation

/// A page that can produce pixels while it is hidden.
///
/// A hidden Chromium page draws no frames, so a DevTools screenshot of a
/// background tab waits for a frame that never comes. Automation wraps a
/// capture of a page that may be hidden in ``withContentVisibleForCapture(_:)``:
/// the engine treats the page as visible for the duration, without drawing it
/// on screen, then hides it again.
///
/// ```swift
/// let png = try await (page as? any BrowserPageHiddenCapturing)?
///     .withContentVisibleForCapture { try await page.takeSnapshot(rect: nil) }
/// ```
@MainActor
public protocol BrowserPageHiddenCapturing: AnyObject {
    /// Runs `body` with the page visible to its engine but not on screen.
    /// Calls may nest; the page is hidden again when the outermost one ends.
    /// A page that is already on screen runs `body` unchanged.
    /// - Parameter body: The capture.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    func withContentVisibleForCapture<T>(_ body: () async throws -> T) async rethrows -> T
}
