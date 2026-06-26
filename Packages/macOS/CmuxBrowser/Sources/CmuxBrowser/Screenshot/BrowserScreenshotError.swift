/// An error raised while capturing or exporting a browser screenshot.
///
/// The cases live in this package so screenshot capture code here can `throw`
/// and pattern-match them. The localized `LocalizedError` descriptions (the
/// `browser.screenshot.error.*` strings) are supplied app-side, where
/// `String(localized:)` resolves against the app bundle that owns the string
/// catalog; resolving them here would bind to the package bundle and silently
/// drop every non-English translation.
public enum BrowserScreenshotError: Error {
    /// The page exceeds the maximum capturable pixel count.
    case captureAreaTooLarge
    /// No snapshot image was produced.
    case emptySnapshot
    /// The requested selection is empty or outside the browser view.
    case invalidSelection
    /// The captured image could not be encoded.
    case invalidImageRepresentation
    /// The screenshot could not be written to the pasteboard.
    case pasteboardWriteFailed
    /// The page dimensions could not be read from the web content.
    case webContentMetricsUnavailable
}
