public import AppKit

/// Answers a WebKit page's `<input type="file">` with a file picker: the one path every WebKit view takes, whether a
/// cmux page on WebKit (`PageOpenPanel`) or a WebKit browser tab (`WebKitTab`), so the made-ahead panel and its
/// dead-panel guard apply to every WebKit file input. ``MadeAheadOpenPanel`` is the app's answerer; a test passes a
/// stand-in, since a test host cannot make an `NSOpenPanel` without its view service.
///
/// Chromium views do not take this path yet: the CEF shim has no file-dialog handler, so a Chromium browser tab's or
/// a Chromium-hosted cmux page's file input gets Chromium's own new `NSOpenPanel` per click (open; the CEF owners
/// add the handler that answers through this protocol).
///
/// ```swift
/// public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
///                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
///     fileInput.answerFileInput(allowsMultipleSelection: parameters.allowsMultipleSelection,
///                               allowsDirectories: parameters.allowsDirectories,
///                               window: webView.window, completion: completionHandler)
/// }
/// ```
@MainActor
public protocol WebFileInputAnswering: AnyObject {
    /// Shows the picker for one file input and calls `completion` exactly once.
    ///
    /// - Parameters:
    ///   - allowsMultipleSelection: Whether the input takes several files (`multiple`).
    ///   - allowsDirectories: Whether the input takes folders (`webkitdirectory`).
    ///   - window: The page's window: the picker shows as a sheet on it, else as its own window.
    ///   - completion: The chosen files, or nil when the person cancelled or no picker could be shown.
    func answerFileInput(allowsMultipleSelection: Bool, allowsDirectories: Bool, window: NSWindow?,
                         completion: @escaping @MainActor ([URL]?) -> Void)
}
