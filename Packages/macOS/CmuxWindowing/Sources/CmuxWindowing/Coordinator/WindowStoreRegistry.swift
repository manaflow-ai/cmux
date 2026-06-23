public import AppKit

/// The single owner of every domain's `WindowID`-keyed per-window store, plus
/// the cross-store bookkeeping that keeps them consistent when a window is
/// (re)bound or torn down.
///
/// ## Why this exists
///
/// The owner ruling (2026-06-18) rejects the legacy `AppDelegate.MainWindowContext`
/// aggregate: per-window state is domain-owned and ``WindowID``-keyed, looked up
/// by each domain in its own `[WindowID: Model]`. The first cut of that ruling
/// scattered six independent ``WindowScopedStore`` properties across the
/// `AppDelegate` singleton (`windowTabManagers`, `windowFocusControllers`,
/// `windowConfigStores`, `windowSidebarStates`, `windowSidebarSelectionStates`,
/// `windowFileExplorerStates`) plus a hand-maintained reverse index
/// (`tabManagerWindowIds`) and an open-coded six-call removal funnel
/// (`removeWindowSlices`). That left the de-aggregation MECHANICS — which stores
/// exist, how they stay in sync, and how a window's slices are dropped atomically
/// — living on the god object with no single owner and no tests.
///
/// `WindowStoreRegistry` is that single owner. It holds the six stores as
/// composed members (not a per-window aggregate VALUE: each store stays an
/// independent `[WindowID: Model]`, honoring the ruling), owns the
/// tab-manager → ``WindowID`` reverse index, owns the new-window cascade point,
/// and exposes the two consistency funnels (``rebindTabManager(_:for:)`` and
/// ``removeSlices(for:)``) so the rebind/remove invariants live in one tested
/// place instead of being re-open-coded at each call site. The app target holds
/// exactly one of these at the composition root and keeps every method that
/// reaches into live AppKit/tab/session state (window creation, routing,
/// teardown orchestration) as the thin app-side shim over this registry.
///
/// ## Generic over the app's per-window model types
///
/// The package never names the app-target model types. Each is a type parameter:
/// `TabManager` (the per-window tabs model, constrained `AnyObject` so the reverse
/// index can key on its object identity exactly as the legacy
/// `ObjectIdentifier(tabManager)` keying did), `FocusController`, `ConfigStore`,
/// `SidebarState`, `SidebarSelectionState`, and `FileExplorerState`. The app
/// constructs the fully-specialized registry at startup; the package stays
/// model-agnostic.
///
/// ## Isolation
///
/// `@MainActor` because every mutator runs on the main thread alongside window
/// registration and AppKit teardown, co-locating the state with its callers so
/// no cross-actor bridge is needed (mirrors ``WindowScopedStore`` and
/// ``RecoverableWindowRouteLedger``). The composed stores are `@MainActor` for
/// the same reason; reaching them through this registry keeps the whole per-window
/// store layer on one actor.
@MainActor
public final class WindowStoreRegistry<
    TabManager: AnyObject,
    FocusController,
    ConfigStore,
    SidebarState,
    SidebarSelectionState,
    FileExplorerState
> {
    /// Per-window tabs models, keyed by ``WindowID``. The window→manager
    /// association is window identity, owned here next to the other slices; the
    /// `TabManager` lifecycle itself remains the tabs domain's.
    public let tabManagers = WindowScopedStore<TabManager>()

    /// Per-window keyboard-focus coordinators, keyed by ``WindowID``.
    public let focusControllers = WindowScopedStore<FocusController>()

    /// Per-window config stores, keyed by ``WindowID``.
    public let configStores = WindowScopedStore<ConfigStore>()

    /// Per-window sidebar (visibility + persisted width) states, keyed by
    /// ``WindowID``.
    public let sidebarStates = WindowScopedStore<SidebarState>()

    /// Per-window sidebar-selection states, keyed by ``WindowID``.
    public let sidebarSelectionStates = WindowScopedStore<SidebarSelectionState>()

    /// Per-window right-sidebar (file-explorer) states, keyed by ``WindowID``.
    /// Its slice is OPTIONAL by design: the legacy field was a lazily-bound
    /// `var FileExplorerState?` (nil until the window's content view seeds it), so
    /// an absent entry faithfully encodes "no file-explorer state yet".
    public let fileExplorerStates = WindowScopedStore<FileExplorerState>()

    /// Reverse index from a live `TabManager` (by object identity) to its
    /// ``WindowID``, kept in sync with ``tabManagers``. Faithfully replaces the
    /// legacy `ObjectIdentifier(tabManager)` keying and the recurring
    /// `registeredMainWindow(forManager:)` scans with an O(1) lookup. Seeded and
    /// updated by ``rebindTabManager(_:for:)`` and torn down by
    /// ``removeSlices(for:)``.
    private var tabManagerWindowIds: [ObjectIdentifier: WindowID] = [:]

    /// Tracks the cascade point for new windows, matching Ghostty's upstream
    /// algorithm. Reset to `.zero` so the first window seeds the point from its
    /// own position. Owned here because it is per-window-set placement state that
    /// every window-create/teardown path reads and writes alongside the stores.
    public var lastCascadePoint: NSPoint = .zero

    /// Creates an empty registry. The app target constructs exactly one,
    /// fully specialized over its per-window model types, at the composition root.
    public init() {}

    /// The ``WindowID`` currently bound to `tabManager` via the reverse index, or
    /// `nil` if none. The O(1) replacement for the legacy
    /// `registeredMainWindow(forManager:)` scan.
    public func windowId(forTabManager tabManager: TabManager) -> WindowID? {
        tabManagerWindowIds[ObjectIdentifier(tabManager)]
    }

    /// Binds `tabManager` to `id` in ``tabManagers`` and keeps the reverse index
    /// consistent: drops any stale reverse entry for a manager previously bound to
    /// `id`, records the new mapping, then stores the manager. Faithfully
    /// reproduces the legacy `rebindWindowTabManager`.
    public func rebindTabManager(_ tabManager: TabManager, for id: WindowID) {
        if let previous = tabManagers.model(for: id), previous !== tabManager {
            tabManagerWindowIds.removeValue(forKey: ObjectIdentifier(previous))
        }
        tabManagers.setModel(tabManager, for: id)
        tabManagerWindowIds[ObjectIdentifier(tabManager)] = id
    }

    /// Drops every per-window slice for `id` across all six domain stores plus the
    /// reverse index, returning the removed tabs manager and focus controller (the
    /// teardown paths need them to clear notifications, remember recoverable
    /// routes, and drop observers).
    ///
    /// Returns `nil` when `id` has no tabs slice (already torn down), matching the
    /// legacy `removeWindowSlices` guard so a double teardown is a no-op. The
    /// single removal funnel for both window teardown paths (the AppKit close path
    /// and the explicit/windowless path), faithfully reproducing the legacy
    /// `mainWindowContexts.removeValue` plus the per-store `remove(_:)` calls.
    @discardableResult
    public func removeSlices(
        for id: WindowID
    ) -> (tabManager: TabManager, focusController: FocusController?)? {
        guard let tabManager = tabManagers.remove(id) else { return nil }
        tabManagerWindowIds.removeValue(forKey: ObjectIdentifier(tabManager))
        let focusController = focusControllers.remove(id)
        configStores.remove(id)
        sidebarSelectionStates.remove(id)
        sidebarStates.remove(id)
        fileExplorerStates.remove(id)
        return (tabManager, focusController)
    }
}
