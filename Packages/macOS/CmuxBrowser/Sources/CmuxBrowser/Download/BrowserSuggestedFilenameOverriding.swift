public import WebKit

/// A download delegate that accepts a filename chosen by page script.
///
/// `CmuxWebView` routes script-initiated downloads (`<a download="...">`,
/// blob URLs) through WebKit and hands the page's filename to the web view's
/// download delegate before WebKit asks for a destination.
public protocol BrowserSuggestedFilenameOverriding: AnyObject {
    /// Uses `suggestedFilename` for `download` instead of WebKit's suggestion.
    /// Blank names are ignored.
    func setSuggestedFilenameOverride(_ suggestedFilename: String?, for download: WKDownload)
}

/// A download delegate that wants scripted `data:` downloads (a page's
/// `<a download>` links) as WebKit downloads it receives, rather than saved
/// directly by the web view. The browser REPL uses this so a driven tab
/// reports those downloads to its session. Read on the main thread.
public protocol BrowserScriptedDownloadRouting: AnyObject {
    var routesScriptedDownloadsThroughWebKit: Bool { get }
}
