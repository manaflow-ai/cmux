public import Foundation

/// The window-side seam ``WorkspaceSelectionSideEffectsCoordinator`` drives for
/// the selection side effects it cannot own from the package: the app-coupled
/// pieces of the legacy `TabManager.selectedTabId` `didSet` chain.
///
/// The coordinator owns the focus-history record ordering (over the
/// CmuxWorkspaces ``FocusedSurfaceModel`` / ``FocusHistoryNavigating`` models)
/// and the generation guard for the deferred turn. Everything that reaches the
/// app-target god objects or a sibling package inverts through this host: the
/// Sentry breadcrumb, the previous-selection focused-panel read, the
/// `CmuxWorkspaceSelected` lifecycle publish, the notification-dismissal context
/// take, the DEBUG workspace-switch tracing, the `DispatchQueue.main.async`
/// deferred hop, and the deferred AppKit effects (window-title update +
/// focused-panel notification dismissal).
///
/// The per-window `TabManager` is the single implementer. Splitting it this way
/// keeps the side-effect *ordering* and the generation bookkeeping in the
/// package while the `Workspace` god-object reads, the cross-package
/// `NotificationDismissalContext`, and the DEBUG instrumentation stay app-side,
/// exactly where those types live.
///
/// `@MainActor` for the same reason as the coordinator: the whole selection
/// chain runs in one main-actor turn driven by a `selectedTabId` assignment, so
/// the host lives where its callers live and no bridging is needed.
@MainActor
public protocol WorkspaceSelectionSideEffectsHosting: AnyObject {
    /// Whether a session-snapshot restore is in progress. When `true` the
    /// selection chain skips the group auto-expand so it does not mutate
    /// restored state mid-restore (legacy `isRestoringSessionSnapshot` guard).
    var isSelectionSideEffectsRestoring: Bool { get }

    /// Records the `workspace.switch` Sentry breadcrumb with the live workspace
    /// count (legacy `sentryBreadcrumb("workspace.switch", data: ["tabCount":
    /// tabs.count])`).
    func recordWorkspaceSwitchBreadcrumb(tabCount: Int)

    /// The panel id currently focused in `workspaceId` (legacy
    /// `focusedPanelId(for:)`), used to seed the previous-selection
    /// focus-history entry. Shared with ``ClosedBrowserPanelReopenHosting``.
    func focusedPanelId(forWorkspaceId workspaceId: UUID) -> UUID?

    /// Publishes the `CmuxWorkspaceSelected` lifecycle change to the rest of the
    /// app (legacy `publishCmuxWorkspaceSelectedChange(from:)`).
    func publishWorkspaceSelectedChange(fromPreviousWorkspaceId previousWorkspaceId: UUID?)

    /// Takes (and clears) the pending notification-dismissal context for this
    /// selection and stashes it app-side for the deferred dismissal, falling
    /// back to the active-focus default (legacy
    /// `notificationDismissal.takePendingSelectionContext() ?? .activeFocus`).
    ///
    /// Called synchronously at the same point the legacy `didSet` captured the
    /// context. The package never names `NotificationDismissalContext` (owned by
    /// a sibling package); it stays entirely app-side between this take and the
    /// deferred ``applyDeferredSelectionAppEffects()``.
    func takePendingNotificationDismissalContextForDeferredSideEffects()

    /// Schedules the deferred selection side-effect turn on the next main-actor
    /// runloop hop (legacy `DispatchQueue.main.async`). The host's hop must call
    /// back into
    /// ``WorkspaceSelectionSideEffectsCoordinator/runDeferredSelectionSideEffects(generation:previousWorkspaceId:)``
    /// with the same `generation` and `previousWorkspaceId`.
    func scheduleDeferredSelectionSideEffects(generation: UInt64, previousWorkspaceId: UUID?)

    /// Runs the deferred AppKit selection effects, in order: update the window
    /// title for the selected workspace, then dismiss the focused panel's active
    /// notification using the context taken in
    /// ``takePendingNotificationDismissalContextForDeferredSideEffects()`` (legacy
    /// `updateWindowTitleForSelectedTab()` + `dismissFocusedPanelNotificationIfActive`).
    ///
    /// Invoked by the coordinator inside the focus-history suppression wrap so
    /// it interleaves with the model-side focus exactly as the legacy closure did.
    func applyDeferredSelectionAppEffects()

    // MARK: DEBUG switch tracing (no-op in release builds)

    /// Logs that `selectedTabId` changed from `previousWorkspaceId` to
    /// `selectedWorkspaceId` (legacy DEBUG `workspaceSwitchDebug
    /// .logSelectionDidChange(from:to:)`). No-op in release builds.
    func debugLogSelectionDidChange(
        fromPreviousWorkspaceId previousWorkspaceId: UUID?,
        toSelectedWorkspaceId selectedWorkspaceId: UUID?
    )

    /// Logs that the deferred selection side effects finished for the current
    /// selection (legacy DEBUG `workspaceSwitchDebug.logSelectionSideEffectsDone
    /// (selected:)`). No-op in release builds.
    func debugLogSelectionSideEffectsDone()
}
