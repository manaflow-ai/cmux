import AppKit
import Foundation

/// Internal backend protocol. Two implementations:
/// - `WebKitBrowserBackend`: wraps `WKWebView` (the current engine).
/// - `ChromiumBrowserBackend`: stub today; will be wired to
///   `CmuxCore.framework` once the Chromium fork builds (see
///   `plans/chromium-engine.md`).
///
/// Methods are sync where the underlying API is sync, and async-completion
/// where the underlying API is async. The Swift surface is
/// `WKWebView`-shaped intentionally; `CmuxBrowserView` forwards to the
/// backend without translation.
@MainActor
protocol CmuxBrowserBackend: AnyObject {
    /// The host view to insert into the AppKit hierarchy.
    var nsView: NSView { get }

    var url: URL? { get }
    var title: String? { get }
    var isLoading: Bool { get }
    var estimatedProgress: Double { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }

    var navigationDelegate: CmuxNavigationDelegate? { get set }
    var uiDelegate: CmuxUIDelegate? { get set }
    var downloadDelegate: CmuxDownloadDelegate? { get set }

    func load(_ request: URLRequest) -> CmuxNavigation
    func loadHTMLString(_ html: String, baseURL: URL?) -> CmuxNavigation
    @discardableResult func goBack() -> CmuxNavigation?
    @discardableResult func goForward() -> CmuxNavigation?
    @discardableResult func reload() -> CmuxNavigation?
    func stopLoading()

    func evaluateJavaScript(
        _ source: String,
        completionHandler: @escaping (Any?, Error?) -> Void
    )

    func setCustomUserAgent(_ userAgent: String?)
    var customUserAgent: String? { get }

    /// Live state mirror. Backends push updates here as the engine
    /// emits them (KVO in WebKit, delegate callbacks in Chromium).
    var state: CmuxBrowserState { get }

    /// Page zoom factor. 1.0 = no zoom.
    var pageZoom: CGFloat { get set }

    /// Snapshot the current visible region as a `CGImage`. Passing
    /// `nil` uses engine defaults (full view, current width).
    func takeSnapshot(
        configuration: CmuxSnapshotConfiguration?,
        completionHandler: @escaping (CGImage?, Error?) -> Void
    )
}

/// Errors surfaced to call sites from inside the wrapper.
public enum CmuxBrowserEngineError: Error, Equatable {
    /// The selected backend is not yet implemented in this build.
    case backendUnavailable(CmuxBrowserEngine.Kind, reason: String)
    /// A native handle returned an unexpected value.
    case nativeError(String)
}
