/// Owns the application activation / resign lifecycle sequencing, draining it out
/// of the app delegate.
///
/// This coordinator sequences `applicationWillBecomeActive(_:)`,
/// `applicationDidBecomeActive(_:)`, and `applicationWillResignActive(_:)`: the
/// pre-activation window order-front, the post-activation visibility restore, the
/// did-become-active telemetry (breadcrumb plus analytics), the notification
/// activation/unread reconcile, and the resign-time chord clear plus session
/// snapshot decision. Every live effect (the visibility controller, the
/// breadcrumb/analytics sinks, the notification store and reconciler, the
/// configured-shortcut chord state, and the session snapshot) stays in the
/// composition root behind ``ApplicationActivationHost``; the coordinator never
/// names an app-target type.
///
/// ## Isolation
/// `@MainActor` because every activation/resign callback originates on the main
/// actor in the app delegate. Co-locating this policy with its callers keeps the
/// bridging to the live delegate as plain main-actor calls — the same ruling
/// that shaped ``ApplicationTerminateReplyCoordinator`` and
/// ``SocketListenerLifecycleCoordinator``.
@MainActor
public final class ApplicationActivationCoordinator {
    private let host: any ApplicationActivationHost

    /// Creates the activation/resign lifecycle coordinator.
    ///
    /// - Parameter host: The composition-root seam vending the live visibility,
    ///   telemetry, notification-reconcile, chord, and session-snapshot
    ///   operations.
    public init(host: any ApplicationActivationHost) {
        self.host = host
    }

    /// Sequences `applicationWillBecomeActive(_:)`: order the main windows front
    /// before activation when no main terminal window is visible.
    public func applicationWillBecomeActive() {
        host.orderFrontMainWindowsBeforeActivationIfHidden()
    }

    /// Sequences `applicationDidBecomeActive(_:)`: restore window visibility,
    /// record the lifecycle breadcrumb, track the active analytics event, then
    /// reconcile notification activation/unread state for the active selection.
    public func applicationDidBecomeActive() {
        host.restoreMainWindowVisibilityAfterActivation()
        host.recordDidBecomeActiveBreadcrumb()
        if host.isActiveAnalyticsTrackingEnabled {
            host.trackAnalyticsActive(reason: "didBecomeActive")
        }
        host.reconcileNotificationActivationAfterDidBecomeActive()
    }

    /// Sequences `applicationWillResignActive(_:)`: skip during terminate, clear
    /// the configured-shortcut chord state, then save a scrollback-free session
    /// snapshot if the persistence policy allows it.
    public func applicationWillResignActive() {
        guard !host.isTerminatingApp else { return }
        host.clearConfiguredShortcutChordState()
        host.saveSessionSnapshotOnResignIfNeeded()
    }
}
