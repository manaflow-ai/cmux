public import Observation

/// Transient per-row state that defers a workspace-snapshot recomputation while
/// a sidebar row's context menu is open.
///
/// While a context menu is up, recomputing the row's workspace snapshot would
/// dismiss the menu, so the row stashes the pending snapshot here and replays it
/// after the menu closes. Owned by the row view (`TabItemView`) as `@State`;
/// there is exactly one instance per visible row.
///
/// `@MainActor @Observable` (migrated from `ObservableObject`): the row mutates
/// both properties from its `body`/menu-lifecycle on the main thread and reads
/// them back synchronously, so per-property observation is the faithful successor
/// to the no-`@Published` original.
@MainActor
@Observable
public final class SidebarTabItemContextMenuModel {
    /// True when a workspace-observation invalidation was deferred because the
    /// row's context menu was open; replayed once the menu closes.
    public var hasDeferredWorkspaceObservationInvalidation = false

    /// The workspace snapshot withheld while the context menu is open, applied
    /// when the menu closes.
    public var pendingWorkspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot?

    /// Creates an empty context-menu deferral model.
    public init() {}
}
