/// The live-app seam for the worker-lane `browser.*` navigation commands
/// (`browser.navigate` / `browser.back` / `browser.forward` / `browser.reload`),
/// read by ``ControlBrowserNavigationWorker``.
///
/// The `TabManager` resolution, the `surface_id` handle resolution, the
/// workspace and browser-panel lookup (`Workspace.browserPanel(for:)`), the
/// navigation calls on the live `BrowserPanel`
/// (`navigateSmart` / `goBack` / `goForward` / `reload`), the
/// `workspace_ref` / `surface_ref` / `window_ref` computation against the
/// god-owned handle registry, and the optional post-action accessibility
/// snapshot all live app-side because they reach `WebKit`, the main actor, and
/// the app's per-surface mutable state, which this control package must not
/// import. ``ControlBrowserNavigationReading`` inverts that: the package owns the
/// protocol and the typed request/result values, and the app's conformer
/// performs the reach, returning a ``ControlBrowserNavigationResolution``
/// byte-faithful to the branch the legacy body took.
///
/// ## Isolation
///
/// `Sendable`, NOT `@MainActor`: these commands run on the nonisolated
/// socket-worker lane (PR 5778 moved the JS-evaluating `browser.*` methods
/// there, which the `@MainActor` ``ControlCommandCoordinator`` cannot host). The
/// legacy bodies were `nonisolated` and ran the navigation (and the
/// post-snapshot accessibility walk, deliberately off the main actor so a slow
/// snapshot on a fresh surface cannot block SwiftUI) on the worker thread,
/// hopping to the main actor only inside the `v2MainSync` blocks.
/// ``resolveNavigation(_:)`` preserves that: it is a synchronous, blocking call
/// made from the worker thread, with the main-actor hops kept inside the
/// conformer exactly as before.
public protocol ControlBrowserNavigationReading: Sendable {
    /// Resolves one parsed navigation request against the live browser surface,
    /// returning the typed outcome.
    ///
    /// Runs synchronously on the calling socket-worker thread (the navigation and
    /// the post-snapshot walk run there, matching the legacy bodies).
    ///
    /// - Parameter request: The parsed navigation request.
    /// - Returns: The navigation resolution (tab-manager/surface/url failure, a
    ///   surface-not-found miss, or a completed navigation).
    func resolveNavigation(_ request: ControlBrowserNavigationRequest) -> ControlBrowserNavigationResolution
}
