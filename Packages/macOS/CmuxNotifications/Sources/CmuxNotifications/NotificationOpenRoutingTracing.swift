public import Foundation

/// The `#if DEBUG` UI-test recorder seam driven by
/// ``NotificationOpenRoutingCoordinator``.
///
/// The legacy open-routing trio wove env-gated jump-to-unread capture writes and
/// multi-window open-failure/focus records through every decision branch. Those
/// recorders read live app state (the env sink, `mainWindowContexts`, the
/// per-context `TabManager` and sidebar selection) and exist only in DEBUG
/// builds, so they cannot move into the package. This seam exposes one hook per
/// distinct recorder call site; the coordinator invokes them in the legacy order
/// and the app side reproduces each `#if DEBUG` body verbatim (every hook is an
/// empty no-op in production). The payload literals come from
/// ``NotificationOpenRoutingTrace`` (slice 1), so the producing branches stay
/// byte-identical to the inlined originals.
@MainActor
public protocol NotificationOpenRoutingTracing: AnyObject {
    /// `openNotification` entry: record the call fired with its tab/surface ids.
    func traceOpenCalled(tabId: UUID, surfaceId: UUID?)

    /// No owning context: record the multi-window open failure (missing context).
    func recordOpenFailureMissingContext(tabId: UUID, surfaceId: UUID?, notificationId: UUID?)

    /// No owning context: record that routing fell back to the active window.
    func traceContextMissingUsedFallback()

    /// Record the final open result on the fallback route (`true`/`false`).
    func traceOpenResult(_ ok: Bool)

    /// Owning context found: record that no fallback was used.
    func traceContextFoundNoFallback()

    /// In-context route, window not realized: record the multi-window open
    /// failure (missing window), carrying `contextToken` so the app side can
    /// reconstruct the expected window identifier.
    func recordOpenFailureMissingWindow(
        forContextToken contextToken: AnyObject,
        tabId: UUID,
        surfaceId: UUID?,
        notificationId: UUID?
    )

    /// In-context route, focus failed: record the multi-window open failure
    /// (focus failed) and the jump-to-unread `openResult(false)` capture.
    func traceInContextFocusFailed(
        forContextToken contextToken: AnyObject,
        tabId: UUID,
        surfaceId: UUID?,
        notificationId: UUID?
    )

    /// In-context route, focus succeeded: arm the model-driven jump-to-unread
    /// focus recorder against `contextToken`'s tab manager.
    func recordJumpUnreadFocusFromModelInContext(
        forContextToken contextToken: AnyObject,
        tabId: UUID,
        surfaceId: UUID?
    )

    /// In-context route, open succeeded: record the multi-window focus and the
    /// jump-to-unread `openedInContext` capture.
    func traceInContextOpened(
        forContextToken contextToken: AnyObject,
        tabId: UUID,
        surfaceId: UUID?
    )

    /// Fallback route failed before focus, tagged with `stage`
    /// (`"missing_tabManager"`, `"tab_not_in_active_manager"`, `"missing_window"`).
    func traceFallbackFailed(stage: String)

    /// Fallback route, focus succeeded: arm the model-driven jump-to-unread
    /// focus recorder against the active tab manager.
    func recordJumpUnreadFocusFromModelActive(tabId: UUID, surfaceId: UUID?)

    /// Fallback route, focus failed: record the jump-to-unread fallback-focus
    /// failure capture.
    func traceFallbackFocusFailed()

    /// Fallback route, open succeeded: record the jump-to-unread
    /// `openedInFallback` capture.
    func traceOpenedInFallback()
}
