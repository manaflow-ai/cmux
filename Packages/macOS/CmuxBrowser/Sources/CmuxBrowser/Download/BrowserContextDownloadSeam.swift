public import WebKit
public import Foundation
internal import AppKit

/// The app-side collaborators ``BrowserContextDownloadService`` needs but cannot
/// reach from the `CmuxBrowser` package: the WebKit cookie store / user agent /
/// referer of the owning `WKWebView`, the downloading-state notification, the
/// native-WebKit-action fallback dispatch, the point-based JavaScript URL lookups,
/// and the debug log sink.
///
/// Mirrors ``BrowserDownloadDelegate``'s injected-closure precedent: the owning
/// view supplies these at service construction and the service holds them, so the
/// package never references AppKit responder chains, app capture state, or the
/// app's `cmuxDebugLog` directly. `@MainActor` because the service that holds it is
/// main-actor isolated and every closure runs on the main actor (the closures touch
/// AppKit / WebKit main-thread state). No `Sendable` because the closures capture
/// the non-`Sendable` view; the type lives entirely on the main actor.
@MainActor
public struct BrowserContextDownloadSeam {
    /// Returns the WebKit cookie store the download/copy requests draw cookies
    /// from (`configuration.websiteDataStore.httpCookieStore` of the owning view).
    public let cookieStore: () -> WKHTTPCookieStore

    /// Returns the `Referer` header value to send (the owning view's current URL
    /// absolute string), or `nil`/empty to omit it.
    public let referer: () -> String?

    /// Returns the `User-Agent` header value to send (the owning view's
    /// `customUserAgent`), or `nil`/empty to omit it.
    public let userAgent: () -> String?

    /// Notifies the owner that a context-menu download is or is not in flight.
    public let onDownloadStateChanged: ((Bool) -> Void)?

    /// Runs the captured native WebKit menu action as a fallback, with the trace
    /// id and a reason. Parameters: action, target, sender, traceID, reason.
    public let runFallback: ((Selector?, AnyObject?, Any?, String, String) -> Void)?

    /// Resolves the topmost image URL near a view-coordinate point via JavaScript,
    /// calling back with the URL or `nil`.
    public let findImageURLAtPoint: (NSPoint, @escaping (URL?) -> Void) -> Void

    /// Resolves the nearby link URL near a view-coordinate point via JavaScript,
    /// calling back with the URL or `nil`.
    public let findLinkURLAtPoint: (NSPoint, @escaping (URL?) -> Void) -> Void

    /// Optional debug-log sink for the former `#if DEBUG`-guarded context-download
    /// trace messages; `nil` in release builds so the traces compile out at the
    /// wiring site.
    public let log: ((String) -> Void)?

    /// Creates the seam from the owning view's collaborators.
    public init(
        cookieStore: @escaping () -> WKHTTPCookieStore,
        referer: @escaping () -> String?,
        userAgent: @escaping () -> String?,
        onDownloadStateChanged: ((Bool) -> Void)?,
        runFallback: ((Selector?, AnyObject?, Any?, String, String) -> Void)?,
        findImageURLAtPoint: @escaping (NSPoint, @escaping (URL?) -> Void) -> Void,
        findLinkURLAtPoint: @escaping (NSPoint, @escaping (URL?) -> Void) -> Void,
        log: ((String) -> Void)?
    ) {
        self.cookieStore = cookieStore
        self.referer = referer
        self.userAgent = userAgent
        self.onDownloadStateChanged = onDownloadStateChanged
        self.runFallback = runFallback
        self.findImageURLAtPoint = findImageURLAtPoint
        self.findLinkURLAtPoint = findLinkURLAtPoint
        self.log = log
    }
}
