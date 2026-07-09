import CmuxBrowser
import CmuxControlSocket

/// Bridges the worker-lane blocking-await primitive to the cookie repository's
/// await seam.
///
/// `ControlBrowserEvalAwaiter` (CmuxControlSocket) and
/// ``BrowserCookieStoreAwaiting`` (CmuxBrowser) are two leaf packages with no
/// dependency edge between them, so this conformance lives in the app target,
/// the single point that links both. The method shape is already identical
/// (`await(timeout:start:)` on a `Sendable` value), so the conformance is empty:
/// the cookie repository drives a `WKHTTPCookieStore` callback on the exact same
/// bounded blocking-await the browser JS-eval lane uses.
extension ControlBrowserEvalAwaiter: @retroactive BrowserCookieStoreAwaiting {}
