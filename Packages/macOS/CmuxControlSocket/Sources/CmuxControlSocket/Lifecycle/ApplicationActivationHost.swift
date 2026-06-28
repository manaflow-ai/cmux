/// The irreducible live-AppKit and app-target operations the application
/// activation / resign lifecycle sequencing needs from the composition root.
///
/// ``ApplicationActivationCoordinator`` owns the sequencing of
/// `applicationWillBecomeActive(_:)`, `applicationDidBecomeActive(_:)`, and
/// `applicationWillResignActive(_:)`. The concrete work it sequences — the main
/// window visibility controller's pre/post-activation order-front and restore,
/// the did-become-active breadcrumb and analytics sinks, the notification store
/// and unread reconciler, the configured-shortcut chord state, and the session
/// snapshot — stays in the app target and is reached only through this seam.
///
/// Every member is `@MainActor`: each activation/resign callback originates on
/// the main actor in the app delegate, mirroring the
/// ``ApplicationTerminationHost`` ruling that co-locates the policy with its
/// main-actor callers.
@MainActor
public protocol ApplicationActivationHost: AnyObject {
    /// Orders the main windows front before activation when no main terminal
    /// window is visible. Wraps the `hasVisibleMainTerminalWindow` guard and the
    /// visibility controller's `orderFrontApplicationWindowsBeforeActivation`.
    func orderFrontMainWindowsBeforeActivationIfHidden()

    /// Restores main window visibility after activation: finishes a pending
    /// activation restore, or restores windows after activation when none is
    /// pending and no main terminal window is visible. Binds the activation
    /// window list once, matching the delegate's original body.
    func restoreMainWindowVisibilityAfterActivation()

    /// Records the `app.didBecomeActive` lifecycle breadcrumb with the current
    /// tab count.
    func recordDidBecomeActiveBreadcrumb()

    /// Whether active-state analytics tracking is enabled for this launch
    /// (telemetry enabled for the current launch and not running under XCTest).
    var isActiveAnalyticsTrackingEnabled: Bool { get }

    /// Tracks an active event with the given reason via analytics.
    func trackAnalyticsActive(reason: String)

    /// Notifies the notification store of activation, then reconciles unread
    /// state for the active tab/surface selection. Preserves the delegate's
    /// guard chain so the reconcile is skipped when no store, tab manager, or
    /// selected tab is present.
    func reconcileNotificationActivationAfterDidBecomeActive()

    /// Whether the app is currently terminating; resign work is skipped during
    /// terminate.
    var isTerminatingApp: Bool { get }

    /// Clears any in-progress configured-shortcut chord state.
    func clearConfiguredShortcutChordState()

    /// Saves a scrollback-free session snapshot on resign if the session
    /// persistence policy allows it.
    func saveSessionSnapshotOnResignIfNeeded()
}
