public import Foundation

/// The notification-domain slice of the control-command seam (a constituent of
/// the ``ControlCommandContext`` umbrella).
///
/// The app target (today `TerminalController`, the interim composition owner)
/// conforms by reaching the `TerminalNotificationStore`, `AppDelegate`, and
/// workspace/surface resolution. Every method is `@MainActor` because its
/// conformer and the coordinator both live on the main actor, so these are
/// plain in-isolation calls — the per-read `v2MainSync` hops the legacy command
/// bodies used disappear once the domain moves onto the coordinator.
///
/// No app types cross the seam: deliveries take pre-parsed selectors/ids and
/// return small Sendable resolution enums, and reads return
/// ``ControlNotificationSnapshot`` values.
@MainActor
public protocol ControlNotificationContext: AnyObject {
    /// Delivers a notification for `notification.create`: resolves the
    /// TabManager and workspace from `routing`, optionally validating
    /// `explicitSurfaceID`, then delivers to that surface or the workspace's
    /// focused surface.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager + workspace
    ///     resolution (legacy `v2ResolveTabManager` / `v2ResolveWorkspace`).
    ///   - explicitSurfaceID: The explicit `surface_id` to validate and target,
    ///     if the request carried one. Validation uses only this strict
    ///     `surface_id` (not the `terminal_id`/`tab_id` aliases).
    ///   - title: The notification title.
    ///   - subtitle: The notification subtitle.
    ///   - body: The notification body.
    /// - Returns: The delivery resolution.
    func controlNotificationCreate(
        routing: ControlRoutingSelectors,
        explicitSurfaceID: UUID?,
        title: String,
        subtitle: String,
        body: String
    ) -> ControlNotificationCreateResolution

    /// Delivers a notification for `notification.create_for_surface`: resolves
    /// the TabManager and workspace from `routing`, requires `surfaceID` to
    /// exist in that workspace, then delivers and echoes the workspace/surface/
    /// window identity.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors for TabManager + workspace resolution.
    ///   - surfaceID: The required target surface.
    ///   - title: The notification title.
    ///   - subtitle: The notification subtitle.
    ///   - body: The notification body.
    /// - Returns: The targeted delivery resolution (workspace-not-found carries
    ///   `nil`, matching the legacy `data: nil`).
    func controlNotificationCreateForSurface(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        title: String,
        subtitle: String,
        body: String
    ) -> ControlNotificationTargetedDeliveryResolution

    /// Delivers a notification for `notification.create_for_target`: resolves
    /// the TabManager from `routing`, finds the workspace `workspaceID` within
    /// it, requires `surfaceID` to exist there, then delivers and echoes the
    /// workspace/surface/window identity.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors for TabManager resolution.
    ///   - workspaceID: The required target workspace (looked up in the resolved
    ///     TabManager's tabs).
    ///   - surfaceID: The required target surface.
    ///   - title: The notification title.
    ///   - subtitle: The notification subtitle.
    ///   - body: The notification body.
    /// - Returns: The targeted delivery resolution (workspace-not-found carries
    ///   `workspaceID`, matching the legacy `data.workspace_id`).
    func controlNotificationCreateForTarget(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        surfaceID: UUID,
        title: String,
        subtitle: String,
        body: String
    ) -> ControlNotificationTargetedDeliveryResolution

    /// Snapshots every notification for `notification.list`, in store order,
    /// with read state included.
    func controlNotificationList() -> [ControlNotificationSnapshot]

    /// Removes every read notification for `notification.dismiss` with
    /// `all_read`.
    ///
    /// - Returns: How many notifications were removed.
    func controlNotificationDismissAllRead() -> Int

    /// Removes the notification with the given id for `notification.dismiss`
    /// with an `id` selector.
    ///
    /// - Parameter id: The notification to dismiss.
    /// - Returns: The dismiss resolution (the pre-removal snapshot on success).
    func controlNotificationDismiss(id: UUID) -> ControlNotificationDismissResolution

    /// Marks the notification with the given id read for `notification.mark_read`
    /// with an `id` selector.
    ///
    /// - Parameter id: The notification to mark read.
    /// - Returns: The mark-read resolution.
    func controlNotificationMarkRead(id: UUID) -> ControlNotificationMarkReadResolution

    /// Marks notifications read for `notification.mark_read` with a workspace
    /// selector (`tab_id`/`workspace_id`), optionally scoped to a surface.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace whose notifications to mark read.
    ///   - surfaceID: The surface to scope to, when `hasSurfaceSelector` is true.
    ///   - hasSurfaceSelector: Whether the request carried a `surface_id`
    ///     selector (the legacy `surfaceId`-aware vs workspace-wide branch).
    /// - Returns: How many notifications flipped from unread to read.
    func controlNotificationMarkRead(
        workspaceID: UUID,
        surfaceID: UUID?,
        hasSurfaceSelector: Bool
    ) -> Int

    /// Marks every notification read for `notification.mark_read` with `all`.
    ///
    /// - Returns: How many notifications flipped from unread to read.
    func controlNotificationMarkReadAll() -> Int

    /// Opens the target of the notification with the given id for
    /// `notification.open`, re-reading the (possibly mutated) notification for
    /// the response.
    ///
    /// - Parameter id: The notification to open.
    /// - Returns: The open resolution.
    func controlNotificationOpen(id: UUID) -> ControlNotificationOpenResolution

    /// Jumps to and opens the latest unread notification for
    /// `notification.jump_to_unread`.
    ///
    /// - Returns: The opened notification's snapshot, or `nil` when there was
    ///   nothing unread to open.
    func controlNotificationJumpToUnread() -> ControlNotificationSnapshot?

    /// Enqueues clearing all notifications for `notification.clear`.
    func controlNotificationClear()

    /// The localized notification-domain error strings, resolved against the
    /// app's `Localizable.xcstrings` (the package bundle lacks these keys, so
    /// the coordinator must not call `String(localized:)` itself — that would
    /// drop non-English localizations). The app conformance supplies them with
    /// the identical keys and default values the legacy bodies used.
    var notificationStrings: ControlNotificationStrings { get }
}
