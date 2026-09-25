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
