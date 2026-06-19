/// The live-app seam for the worker-lane `browser.find.*` element locators, read
/// by ``ControlBrowserQueryWorker``.
///
/// The panel resolution (`TabManager` → `Workspace` → browser surface →
/// `WKWebView`), the finder-script construction (the `BrowserControlService`
/// builders that live in `CmuxBrowser`), the JavaScript evaluation, the decoded
/// result inspection, the per-surface element-ref allocation, and the
/// document-load kick all live app-side because they reach `WebKit` and the
/// app's per-surface mutable state, which this control package must not import.
/// ``ControlBrowserQueryReading`` inverts that: the package owns the protocol and
/// the typed request/result values, and the app's conformer performs the reach,
/// returning a ``ControlBrowserFindResolution`` byte-faithful to the branch the
/// legacy `v2BrowserFind*` body took.
///
/// ## Isolation
///
/// `Sendable`, NOT `@MainActor`: `browser.find.*` runs on the nonisolated
/// socket-worker lane. The legacy bodies were `nonisolated` and ran the blocking
/// `v2RunBrowserJavaScript` evaluation on the worker thread, hopping to the main
/// actor only inside `v2BrowserWithPanelContext` / `v2BrowserResolveSelector` /
/// `v2BrowserAllocateElementRef`. ``resolveFind(_:)`` preserves that: it is a
/// synchronous, blocking call made from the worker thread, with the main-actor
/// hops kept inside the conformer exactly as before.
public protocol ControlBrowserQueryReading: Sendable {
    /// Resolves one parsed `browser.find.*` request against the live browser
    /// surface, returning the typed outcome.
    ///
    /// Runs synchronously on the calling socket-worker thread (the JavaScript
    /// evaluation blocks there, matching the legacy bodies).
    ///
    /// - Parameter request: The parsed, validated find request.
    /// - Returns: The find resolution (panel failure, selector-ref miss, JS
    ///   error, not-found, or a matched element).
    func resolveFind(_ request: ControlBrowserFindRequest) -> ControlBrowserFindResolution
}
