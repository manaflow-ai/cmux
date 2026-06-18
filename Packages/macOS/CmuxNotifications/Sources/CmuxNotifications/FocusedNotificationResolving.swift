public import Foundation

/// The focused-notification seam: resolves which workspace/surface is focused
/// (first-responder terminal, else the key/main window's selected tab, else the
/// active tab manager), resolves that surface to an owning panel, and exposes
/// the per-workspace/per-panel unread predicates and mutations the focused-mark
/// state machine consults. Keyed by workspace id and an opaque ``FocusedPanel``
/// handle so the marker never holds a `Workspace`, `TabManager`, `NSWindow`, or
/// first-responder reference.
///
/// Each method mirrors one app-side resolver/predicate/mutator lifted out of
/// `AppDelegate`'s focused-mark cluster:
///
/// - ``focusedTarget(preferredWindowToken:)`` mirrors
///   `AppDelegate.focusedNotificationTarget(preferredWindow:)`.
/// - ``focusedPanel(forTabId:surfaceId:)`` mirrors
///   `AppDelegate.focusedPanelNotificationTarget(_:)`.
/// - The `panel*`/`workspace*` reads mirror the corresponding `Workspace` and
///   `TerminalNotificationStore` predicates the original inline bodies called.
/// - The `mark*`/`clear*` methods mirror the matching store/workspace mutations.
///
/// `preferredWindowToken` is the opaque value the app passes through for the
/// preferred-window argument; the package never inspects it. A missing focused
/// target makes ``focusedTarget(preferredWindowToken:)`` return `nil`, exactly
/// like the original guard.
@MainActor
public protocol FocusedNotificationResolving: AnyObject {
    /// Whether a notification store is present. Mirrors the legacy
    /// `guard let notificationStore` entry gate on `toggleFocusedNotificationUnread`
    /// and `markFocusedNotificationAsOldestUnread`: both returned early (no-op)
    /// when the store was absent, even though most of their body never touched it.
    var hasNotificationStore: Bool { get }

    /// The currently-focused workspace/surface, or `nil` when nothing is
    /// focused. Mirrors `focusedNotificationTarget(preferredWindow:)`.
    func focusedTarget(preferredWindowToken: AnyObject?) -> FocusedNotificationTarget?

    /// Resolves `surfaceId` to the owning panel within `tabId`'s workspace, or
    /// `nil` when there is no surface or no owning panel. Mirrors
    /// `focusedPanelNotificationTarget(_:)`.
    func focusedPanel(forTabId tabId: UUID, surfaceId: UUID?) -> FocusedPanel?

    // MARK: Panel predicates (Workspace + store, keyed by tab/panel)

    /// Whether the focused panel carries a session-restored unread indicator.
    /// Mirrors `workspace.hasRestoredUnreadIndicator(panelId:)`.
    func panelHasRestoredUnread(_ panel: FocusedPanel) -> Bool

    /// Whether the workspace has a workspace-contributing restored unread
    /// indicator. Mirrors `workspace.hasWorkspaceContributingRestoredUnreadIndicator`.
    func workspaceHasContributingRestoredUnread(_ panel: FocusedPanel) -> Bool

    /// Whether the focused panel is in the workspace's manual-unread set.
    /// Mirrors `workspace.manualUnreadPanelIds.contains(panelId)`.
    func panelIsManualUnread(_ panel: FocusedPanel) -> Bool

    /// Whether the focused panel is the representative panel for the workspace's
    /// manual unread. Mirrors
    /// `workspace.representativePanelIdForWorkspaceManualUnread() == panelId`.
    func panelIsRepresentativeForWorkspaceManualUnread(_ panel: FocusedPanel) -> Bool

    // MARK: Store predicates (keyed by tab)

    /// Whether the workspace shows a visible notification indicator (surface
    /// `nil` = workspace level). Mirrors
    /// `notificationStore.hasVisibleNotificationIndicator(forTabId:surfaceId:)`.
    func hasVisibleNotificationIndicator(forTabId tabId: UUID, surfaceId: UUID?) -> Bool

    /// Whether the workspace carries a manually-set unread indicator. Mirrors
    /// `notificationStore.hasManualUnread(forTabId:)`.
    func storeHasManualUnread(forTabId tabId: UUID) -> Bool

    /// Whether the workspace carries a session-restored unread indicator.
    /// Mirrors `notificationStore.hasRestoredUnreadIndicator(forTabId:)`.
    func storeHasRestoredUnread(forTabId tabId: UUID) -> Bool

    /// Whether the workspace is unread at the workspace level. Mirrors
    /// `notificationStore.workspaceIsUnread(forTabId:)`.
    func workspaceIsUnread(forTabId tabId: UUID) -> Bool

    // MARK: Mutations

    /// Marks the workspace read. Mirrors `notificationStore.markRead(forTabId:)`.
    func storeMarkRead(forTabId tabId: UUID)

    /// Marks the workspace unread. Mirrors `notificationStore.markUnread(forTabId:)`.
    func storeMarkUnread(forTabId tabId: UUID)

    /// Clears the workspace's manual unread. Mirrors
    /// `notificationStore.clearManualUnread(forTabId:)`.
    func storeClearManualUnread(forTabId tabId: UUID)

    /// Marks the focused panel read. Mirrors `workspace.markPanelRead(_:)`.
    func markPanelRead(_ panel: FocusedPanel)

    /// Marks the focused panel unread. Mirrors `workspace.markPanelUnread(_:)`.
    func markPanelUnread(_ panel: FocusedPanel)

    /// Marks the latest notification for `tabId`/`surfaceId` as oldest-unread,
    /// returning its id when one was deferred. Mirrors
    /// `notificationStore.markLatestNotificationAsOldestUnread(forTabId:surfaceId:)`.
    func markLatestNotificationAsOldestUnread(forTabId tabId: UUID, surfaceId: UUID?) -> UUID?
}
