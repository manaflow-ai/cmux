public import Foundation
public import CmuxCore

/// A seam the favicon service uses to reach the live page and its remote-proxy
/// environment without ever touching the web view, the window, or panel state.
///
/// The app target conforms a thin adapter over the panel's `WKWebView` (held
/// weakly) to this protocol so ``BrowserFaviconService`` never imports WebKit and
/// never reads panel state directly. WebKit's `evaluateJavaScript` is main-thread
/// only and the favicon flow reads the panel's current web-view identity and its
/// remote-proxy inputs synchronously between `await` points, so the seam is
/// `@MainActor`.
@MainActor
public protocol BrowserFaviconScriptEvaluating: AnyObject {
    /// Returns whether the panel's live web view still matches the identity that
    /// started the in-flight favicon refresh.
    ///
    /// The favicon flow re-checks this between every `await` point so a profile
    /// switch or navigation that replaces the web view abandons a stale fetch.
    /// - Parameter instanceID: The web-view instance identity captured when the
    ///   refresh began.
    /// - Returns: `true` when the live web view still carries `instanceID`.
    func isCurrentWebView(instanceID: UUID) -> Bool

    /// Evaluates `script` in the panel's live page and returns the raw string
    /// result, or `nil` when the script produces no string or the timeout elapses.
    ///
    /// Conformers forward to the underlying web view's `evaluateJavaScript`,
    /// racing it against `timeoutNanoseconds` so a wedged page never stalls the
    /// favicon flow.
    /// - Parameters:
    ///   - script: The icon-discovery script to run.
    ///   - timeoutNanoseconds: The maximum time to wait for a result.
    /// - Returns: The script's string result, or `nil`.
    func evaluateJavaScriptString(_ script: String, timeoutNanoseconds: UInt64) async -> String?

    /// Returns `request` rewritten for the panel's active remote-workspace proxy,
    /// or the input unchanged when no proxy is active or the URL is not rewritable.
    ///
    /// Mirrors the panel's outbound URL-rewrite path so favicon fetches reach the
    /// loopback proxy alias host exactly like page navigations do.
    /// - Parameter request: The favicon `URLRequest` to prepare.
    /// - Returns: The proxy-prepared request.
    func remoteProxyPreparedRequest(from request: URLRequest) -> URLRequest

    /// The panel's active remote-workspace proxy endpoint, or `nil` when the panel
    /// is not bound to a remote workspace.
    ///
    /// When present, the favicon fetch tunnels through a SOCKS `URLSession` built
    /// for this endpoint; when `nil`, it uses the shared session directly.
    var remoteProxyEndpoint: BrowserProxyEndpoint? { get }
}
