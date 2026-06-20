/// The live-app seam for the worker-lane `browser.*` interaction commands, read
/// by ``ControlBrowserInteractionWorker``.
///
/// The panel resolution (`TabManager` → `Workspace` → browser surface →
/// `WKWebView`), the per-action script construction (the `BrowserControlService`
/// builders that live in `CmuxBrowser`), the shared `v2BrowserSelectorAction`
/// retry loop (still shared with the not-yet-extracted `browser.get.*` /
/// `browser.is.*` query commands), the JavaScript evaluation, the not-found
/// diagnostics, the element-ref resolution, and the `--snapshot-after` walk all
/// live app-side because they reach `WebKit` and the app's per-surface mutable
/// state, which this control package must not import.
/// ``ControlBrowserInteractionReading`` inverts that: the package owns the
/// protocol and the typed request/result values, and the app's conformer performs
/// the reach, returning a ``ControlBrowserInteractionResolution`` byte-faithful to
/// the branch the legacy interaction body took.
///
/// ## Isolation
///
/// `Sendable`, NOT `@MainActor`: these commands run on the nonisolated
/// socket-worker lane. The legacy bodies were `nonisolated` and ran the blocking
/// `v2RunBrowserJavaScript` evaluation on the worker thread, hopping to the main
/// actor only inside `v2BrowserWithPanelContext` / `v2BrowserResolveSelector` /
/// `v2BrowserAppendPostSnapshot`. ``resolveInteraction(_:)`` preserves that: it is
/// a synchronous, blocking call made from the worker thread, with the main-actor
/// hops kept inside the conformer exactly as before.
public protocol ControlBrowserInteractionReading: Sendable {
    /// Resolves one parsed `browser.*` interaction request against the live browser
    /// surface, returning the typed outcome.
    ///
    /// Runs synchronously on the calling socket-worker thread (the JavaScript
    /// evaluation blocks there, matching the legacy bodies).
    ///
    /// - Parameter request: The parsed, validated interaction request.
    /// - Returns: The interaction resolution (a pre-shaped result from the shared
    ///   app-side body, or a panel-action success the worker shapes).
    func resolveInteraction(_ request: ControlBrowserInteractionRequest) -> ControlBrowserInteractionResolution
}
