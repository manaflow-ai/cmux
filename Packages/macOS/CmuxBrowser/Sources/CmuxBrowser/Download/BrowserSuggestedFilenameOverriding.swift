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
/// reports those downloads to its session. Read on the main actor, where
/// the web view handles the page's scripted-download message.
public protocol BrowserScriptedDownloadRouting: AnyObject {
    @MainActor
    var routesScriptedDownloadsThroughWebKit: Bool { get }

    /// WebKit made `download` of `url` for the scripted-download request
    /// that the frame `initiator` sent (WebKit's record of the message's
    /// frame, not anything the page says), before it asks for a
    /// destination. The REPL binds that document to the download, so a
    /// session judges who wrote a `data:` download's bytes.
    @MainActor
    func scriptedDownloadStarted(_ download: WKDownload, url: URL, initiator: WKFrameInfo)
}
