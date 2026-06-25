public import Foundation

/// The app-side collaborators ``BrowserContextMenuDownloadFlow`` needs but cannot
/// reach from the `CmuxBrowser` package: the WKWebView point-based JavaScript URL
/// lookups (image / topmost-link / contextmenu-captured-link / nearest-anchor), the
/// URL normalization used only by the debug trace lines, the download / copy
/// network-save operations (forwarded into ``BrowserContextDownloadService``), the
/// `#if DEBUG` element-inspection trace, the native-WebKit-action fallback dispatch,
/// and the `cmuxDebugLog` sink (run through `ContextDownloadDebugRedactor`).
///
/// Mirrors ``BrowserContextDownloadSeam``'s injected-closure precedent: the owning
/// view supplies these at flow construction and the flow holds them, so the package
/// never references AppKit responder chains, WebKit `evaluateJavaScript`, app
/// capture state, or the app's `cmuxDebugLog` directly. `@MainActor` because the
/// flow that holds it is main-actor isolated and every closure runs on the main
/// actor (the closures touch AppKit / WebKit main-thread state). No `Sendable`
/// because the closures capture the non-`Sendable` view; the type lives entirely on
/// the main actor.
@MainActor
public struct BrowserContextMenuDownloadFlowSeam {
    /// Resolves the context-menu link URL near a view-coordinate point (the link
    /// captured at contextmenu time, falling back to a topmost-link hit test),
    /// calling back with the URL or `nil`. Primary resolver for "Download Linked File".
    public let resolveLinkURL: (NSPoint, @escaping (URL?) -> Void) -> Void

    /// Resolves the topmost image URL near a view-coordinate point via JavaScript,
    /// calling back with the URL or `nil`.
    public let findImageURLAtPoint: (NSPoint, @escaping (URL?) -> Void) -> Void

    /// Resolves the topmost nearby link URL near a view-coordinate point via
    /// JavaScript, calling back with the URL or `nil`.
    public let findLinkURLAtPoint: (NSPoint, @escaping (URL?) -> Void) -> Void

    /// Resolves the nearest-anchor URL near a view-coordinate point via JavaScript,
    /// calling back with the URL or `nil`. Final "Download Linked File" fallback.
    public let findLinkAtPoint: (NSPoint, @escaping (URL?) -> Void) -> Void

    /// Returns the Google-redirect-unwrapped form of a URL (otherwise the URL
    /// unchanged), used only by the debug trace lines that log normalized URLs.
    public let normalizedURL: (URL) -> URL

    /// Starts a context-menu download of the URL with the native-fallback action /
    /// target / sender and trace id. Parameters: url, sender, fallbackAction,
    /// fallbackTarget, traceID.
    public let startDownload: (URL, Any?, Selector?, AnyObject?, String) -> Void

    /// Resolves the "Copy Image" source URL near a point (the downloadable image
    /// under the cursor, else the nearby link when it is itself a likely image),
    /// calling back with the URL or `nil`.
    public let resolveCopyImageSourceURL: (NSPoint, @escaping (URL?) -> Void) -> Void

    /// Fetches the image bytes for a "Copy Image" from the source URL, calling back
    /// with the pasteboard payload or `nil`. Parameters: sourceURL, traceID, completion.
    public let fetchCopyPayload: (URL, String, @escaping (BrowserImageCopyPasteboardPayload?) -> Void) -> Void

    /// Writes the copy payload onto the general pasteboard, guarding against a
    /// pasteboard race, returning whether it wrote and whether the caller should run
    /// the native fallback. Parameters: payload, expectedPasteboardChangeCount, traceID.
    public let writeCopyPayload: (BrowserImageCopyPasteboardPayload, Int, String) -> (wrote: Bool, shouldFallback: Bool)

    /// Runs the `#if DEBUG` element-inspection JavaScript and logs its payload.
    /// Parameters: point, traceID, kind.
    public let inspectElements: (NSPoint, String, String) -> Void

    /// Runs the captured native WebKit menu action as a fallback, with the trace id
    /// and a reason. Parameters: action, target, sender, traceID, reason.
    public let runFallback: (Selector?, AnyObject?, Any?, String, String) -> Void

    /// Optional debug-log sink for the former `#if DEBUG`-guarded context-download
    /// trace messages; `nil` in release builds so the traces compile out at the
    /// wiring site.
    public let log: ((String) -> Void)?

    /// Creates the seam from the owning view's collaborators.
    public init(
        resolveLinkURL: @escaping (NSPoint, @escaping (URL?) -> Void) -> Void,
        findImageURLAtPoint: @escaping (NSPoint, @escaping (URL?) -> Void) -> Void,
        findLinkURLAtPoint: @escaping (NSPoint, @escaping (URL?) -> Void) -> Void,
        findLinkAtPoint: @escaping (NSPoint, @escaping (URL?) -> Void) -> Void,
        normalizedURL: @escaping (URL) -> URL,
        startDownload: @escaping (URL, Any?, Selector?, AnyObject?, String) -> Void,
        resolveCopyImageSourceURL: @escaping (NSPoint, @escaping (URL?) -> Void) -> Void,
        fetchCopyPayload: @escaping (URL, String, @escaping (BrowserImageCopyPasteboardPayload?) -> Void) -> Void,
        writeCopyPayload: @escaping (BrowserImageCopyPasteboardPayload, Int, String) -> (wrote: Bool, shouldFallback: Bool),
        inspectElements: @escaping (NSPoint, String, String) -> Void,
        runFallback: @escaping (Selector?, AnyObject?, Any?, String, String) -> Void,
        log: ((String) -> Void)?
    ) {
        self.resolveLinkURL = resolveLinkURL
        self.findImageURLAtPoint = findImageURLAtPoint
        self.findLinkURLAtPoint = findLinkURLAtPoint
        self.findLinkAtPoint = findLinkAtPoint
        self.normalizedURL = normalizedURL
        self.startDownload = startDownload
        self.resolveCopyImageSourceURL = resolveCopyImageSourceURL
        self.fetchCopyPayload = fetchCopyPayload
        self.writeCopyPayload = writeCopyPayload
        self.inspectElements = inspectElements
        self.runFallback = runFallback
        self.log = log
    }
}
