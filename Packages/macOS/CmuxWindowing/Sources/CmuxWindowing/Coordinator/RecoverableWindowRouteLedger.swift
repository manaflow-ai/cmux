/// An ordered, ``WindowID``-keyed store of recoverable main-window routes.
///
/// A "recoverable route" is the app target's record that a main window can still
/// be reached for scripting/automation even though it has dropped out of the
/// live registered-window set (e.g. its terminal surfaces are being recreated
/// during restore). The app keeps these routes so window-resolution commands can
/// still find a window that is momentarily unregistered, retiring a route once
/// the window has no registered terminal surface at all.
///
/// This ledger owns only the irreducible bookkeeping that store carried as a
/// private app-target class behind an `objc_getAssociatedObject` association on
/// the `AppDelegate` singleton: a ``WindowID``-keyed dictionary of route values,
/// a monotonic insertion order issued per remembered route, and the stable
/// sort that orders routes most-recently-remembered first. Lifting it here
/// removes a per-window aggregate hidden on the `AppDelegate` singleton and
/// replaces the association hack with a real constructor-held instance, matching
/// the de-aggregation keystone (``WindowScopedStore`` / ``WindowCoordinator``):
/// per-window state is domain-owned and ``WindowID``-keyed (owner ruling
/// 2026-06-18).
///
/// `Value` is generic so the package never names the app-target route type
/// (which holds `TabManager`/`NSWindow` handles and the surface-registry
/// predicate that decides recoverability); the app constructs
/// `RecoverableWindowRouteLedger<RecoverableMainWindowRoute>` at the composition
/// root and keeps every route-resolution method (which reaches into app-target
/// window/tab/surface state) as the thin app-side shim over this ledger.
///
/// ## Ordering
///
/// Each remembered route is tagged with a monotonically increasing order issued
/// by ``issueOrder()`` at remember time. ``sortedByMostRecentFirst()`` orders
/// routes by descending order (most-recently-remembered first); ties (which the
/// monotonic counter makes unreachable in practice) break by ascending
/// ``WindowID`` UUID string, faithfully reproducing the legacy comparator.
///
/// ## Isolation
///
/// `@MainActor` because every mutator runs on the main thread alongside window
/// registration and AppKit teardown, co-locating the state with its callers so
/// no cross-actor bridge is needed (mirrors ``WindowScopedStore``'s isolation
/// ruling). `Value` is unconstrained because the app-target route type is a
/// `@MainActor` reference type held only on this actor.
@MainActor
public final class RecoverableWindowRouteLedger<Value> {
    /// One remembered route: its value plus the monotonic order it was issued.
    private struct Entry {
        let value: Value
        let order: UInt64
    }

    /// The remembered routes, keyed by ``WindowID``.
    private var entries: [WindowID: Entry] = [:]

    /// The next order to issue. Monotonic for the lifetime of the ledger so the
    /// most-recently-remembered route always sorts first.
    private var nextOrder: UInt64 = 0

    /// Creates an empty ledger. The app target holds exactly one at the
    /// composition root.
    public init() {}

    /// Issues the next monotonic order value, advancing the counter.
    ///
    /// The app calls this once per remembered route and stores the result on the
    /// route value it passes to ``setRoute(_:order:for:)``, mirroring the legacy
    /// `MainWindowRouteLedger.issueOrder()` whose value lived on the route.
    public func issueOrder() -> UInt64 {
        defer { nextOrder &+= 1 }
        return nextOrder
    }

    /// The route remembered for `id`, or `nil` if none.
    public func route(for id: WindowID) -> Value? {
        entries[id]?.value
    }

    /// Remembers `route` under `id` at the given `order`, replacing any prior
    /// route for that window.
    ///
    /// `order` is the value the caller obtained from ``issueOrder()`` (kept on
    /// the route value so the app's route type still exposes its own `order`,
    /// preserving the legacy shape). Passing it in keeps the ledger the single
    /// owner of the ordered storage without the ledger needing to read into the
    /// opaque `Value`.
    public func setRoute(_ route: Value, order: UInt64, for id: WindowID) {
        entries[id] = Entry(value: route, order: order)
    }

    /// Removes and returns the route remembered for `id`, if any. Idempotent if
    /// already gone.
    @discardableResult
    public func remove(_ id: WindowID) -> Value? {
        entries.removeValue(forKey: id)?.value
    }

    /// Whether any route is remembered for `id`.
    public func contains(_ id: WindowID) -> Bool {
        entries[id] != nil
    }

    /// The number of remembered routes. Mirrors the legacy ledger's
    /// `routesByWindowId.count` used in the prune diagnostics.
    public var count: Int {
        entries.count
    }

    /// Every remembered route value, in no guaranteed order.
    public var routes: [Value] {
        entries.values.map(\.value)
    }

    /// Every `(WindowID, route)` pair, in no guaranteed order.
    public var pairs: [(id: WindowID, route: Value)] {
        entries.map { (id: $0.key, route: $0.value.value) }
    }

    /// Keeps only the remembered routes for which `isIncluded` returns `true`,
    /// evaluated with each route's ``WindowID`` and value. Mirrors the legacy
    /// `routesByWindowId.filter` used by the retire sweep. The closure may mutate
    /// state reachable through a reference-typed `Value` (the legacy sweep rebinds
    /// a route's live window on the route object itself before deciding whether to
    /// keep it); the ledger only adds or drops the keyed entry.
    public func retainRoutes(where isIncluded: (WindowID, Value) -> Bool) {
        entries = entries.filter { id, entry in isIncluded(id, entry.value) }
    }

    /// The remembered routes ordered most-recently-remembered first.
    ///
    /// Sorts by descending issued order; ties break by ascending ``WindowID``
    /// UUID string. Faithfully reproduces the legacy
    /// `sortedRecoverableMainWindowRoutes()` comparator.
    public func sortedByMostRecentFirst() -> [Value] {
        entries
            .sorted { lhs, rhs in
                if lhs.value.order != rhs.value.order {
                    return lhs.value.order > rhs.value.order
                }
                return lhs.key.rawValue.uuidString < rhs.key.rawValue.uuidString
            }
            .map(\.value.value)
    }
}
