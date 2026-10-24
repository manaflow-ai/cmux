/// What a gone-tab watcher may read of a store's live tree: the tab-list revision it wakes on,
/// and whether the tree lists one tab.
///
/// The seam is narrow on purpose. A watcher that holds a `LiveTabListing` cannot walk every
/// workspace, screen, pane and tab of the session, so what one tree change costs it is the tabs
/// it tracks, by construction (CLAUDE.md "Go past Chrome where cmux is scripted": a script that
/// moves panes in 50 background workspaces must not make each watcher walk the session).
/// ``DaemonStore`` conforms. A test wraps a store to count the lookups a watcher makes:
///
/// ```swift
/// @MainActor final class CountingLiveTabs: LiveTabListing {
///     let store: DaemonStore
///     var lookups = 0
///     init(_ store: DaemonStore) { self.store = store }
///     var liveTabListRevision: UInt64? { store.liveTabListRevision }
///     func liveTreeLists(tab id: String) -> Bool? {
///         lookups += 1
///         return store.liveTreeLists(tab: id)
///     }
/// }
/// ```
@MainActor
public protocol LiveTabListing: AnyObject, Sendable {
    /// The tab-list revision while the tree is live (connected and loaded), else nil. It changes
    /// when a tab comes, goes or moves: what a watcher observes.
    var liveTabListRevision: UInt64? { get }

    /// Whether the live tree lists the tab with durable id `id`; nil while there is no live tree,
    /// when no tab may be called gone.
    ///
    /// - Parameter id: The tab's durable id (`TabModel.id`).
    /// - Returns: True when listed, false when not, nil without a live tree.
    func liveTreeLists(tab id: String) -> Bool?
}
