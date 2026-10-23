public import AppKit

/// Answers a web page's `<input type="file">` with a file picker: the one path every WebKit view takes, whether an
/// agent composer page (`PageOpenPanel`) or a WebKit browser tab (`WebKitTab`), so the made-ahead panel and its
/// dead-panel guard apply to every file input. ``MadeAheadOpenPanel`` is the app's answerer; a test passes a
/// stand-in, since a test host cannot make an `NSOpenPanel` without its view service.
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
