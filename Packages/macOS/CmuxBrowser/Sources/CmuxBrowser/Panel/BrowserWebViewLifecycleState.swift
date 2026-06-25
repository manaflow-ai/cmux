/// The lifecycle phase of a browser panel's underlying ``WKWebView``.
///
/// Drives lazy realization (a `newTab`/`deferredURL` panel has no live web view
/// until shown), visibility-based suspension (`liveVisible` vs `liveHidden`),
/// and teardown (`discarded`/`closing`). The raw values are stable lifecycle
/// telemetry tokens; do not rename them.
public enum BrowserWebViewLifecycleState: String, Sendable {
    /// A new, empty tab with no pending URL and no live web view yet.
    case newTab = "new_tab"

    /// A tab with a URL queued for its first load, not yet realized.
    case deferredURL = "deferred_url"

    /// A realized web view that is currently on screen.
    case liveVisible = "live_visible"

    /// A realized web view that is off screen and may be suspended.
    case liveHidden = "live_hidden"

    /// The web view has been discarded to reclaim resources.
    case discarded

    /// The panel is tearing down.
    case closing
}

extension BrowserWebViewLifecycleState {
    /// Resolves the lifecycle state for a browser panel from its five primitive
    /// inputs.
    ///
    /// The owning `BrowserPanel` computes these primitives from its live
    /// `@MainActor` state (closing flag, memory-discard flag, render gate,
    /// omnibar URL presence, UI visibility) and calls this to decide the next
    /// phase. The cascade is priority-ordered: closing wins over discard,
    /// discard over the un-rendered (`newTab`/`deferredURL`) split, and a
    /// rendered view resolves to `liveVisible` or `liveHidden` by UI
    /// visibility. The decision is a pure function of value inputs, so it is
    /// fully decoupled from the panel's mutable state; the panel keeps the
    /// `@Published` mirror and the `!=` guard.
    ///
    /// - Parameters:
    ///   - isClosing: Whether the panel is tearing down its lifecycle.
    ///   - isDiscardedForMemory: Whether the hidden web view was discarded to
    ///     reclaim memory.
    ///   - shouldRenderWebView: Whether the panel should render a live web view.
    ///   - hasPreferredURL: Whether the panel has a preferred URL queued for the
    ///     omnibar (a non-`nil` `preferredURLStringForOmnibar()`).
    ///   - isVisibleInUI: Whether the panel's web view is currently visible.
    /// - Returns: The lifecycle state the panel should transition to.
    public static func resolve(
        isClosing: Bool,
        isDiscardedForMemory: Bool,
        shouldRenderWebView: Bool,
        hasPreferredURL: Bool,
        isVisibleInUI: Bool
    ) -> BrowserWebViewLifecycleState {
        if isClosing {
            return .closing
        } else if isDiscardedForMemory {
            return .discarded
        } else if !shouldRenderWebView {
            return hasPreferredURL ? .deferredURL : .newTab
        } else if isVisibleInUI {
            return .liveVisible
        } else {
            return .liveHidden
        }
    }
}
