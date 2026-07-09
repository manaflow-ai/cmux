/// The page-zoom actions the app target drives against the focused markdown
/// preview panel.
///
/// Zoom applies to the rendered-preview `WKWebView`, so the markdown panel
/// conforms to this seam only while showing its preview mode; the raw text-edit
/// mode is deliberately excluded by the app-side resolver. The concrete
/// markdown panel lives in the app target, so this protocol is the inversion
/// seam ``FocusedBrowserController`` forwards through.
///
/// `@MainActor` because zoom mutates WebKit state on the main thread.
@MainActor
public protocol FocusedMarkdownZooming: AnyObject {
    /// Increases the preview zoom by one step. Returns whether the zoom changed.
    @discardableResult
    func zoomIn() -> Bool

    /// Decreases the preview zoom by one step. Returns whether the zoom changed.
    @discardableResult
    func zoomOut() -> Bool

    /// Resets the preview zoom to 100%. Returns whether the zoom changed.
    @discardableResult
    func resetZoom() -> Bool
}
