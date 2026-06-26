/// Orchestrates reloading every per-window cmux configuration store and refreshing
/// window titles, as the app delegate's `reloadCmuxConfigStores(source:)` did.
///
/// Owned by the app delegate and given a weak reference to it through
/// `CmuxConfigStoreReloadEnvironment`, so the delegate retaining the coordinator
/// does not create a retain cycle. The coordinator does no I/O itself; it sequences
/// the stores' own `loadAll()` and the environment's title refresh, deduping shared
/// stores by object identity exactly as before.
@MainActor
public final class CmuxConfigStoreReloadCoordinator {
    private weak var environment: (any CmuxConfigStoreReloadEnvironment)?
    private let onReload: (@MainActor (_ source: String, _ storeCount: Int) -> Void)?

    /// Creates a coordinator.
    /// - Parameters:
    ///   - environment: The source of per-window stores and the title refresher.
    ///     Held weakly because the environment (the app delegate) owns this
    ///     coordinator.
    ///   - onReload: An optional hook invoked after each reload with the reload
    ///     source and the number of distinct stores reloaded. The app target wires
    ///     this to its debug log; tests use it to observe behavior.
    public init(
        environment: any CmuxConfigStoreReloadEnvironment,
        onReload: (@MainActor (_ source: String, _ storeCount: Int) -> Void)? = nil
    ) {
        self.environment = environment
        self.onReload = onReload
    }

    /// Reloads every distinct per-window configuration store, then refreshes window
    /// titles, then reports the reload through `onReload`.
    ///
    /// Distinct stores are determined by object identity so a store shared across
    /// windows reloads once, preserving the original iteration-and-dedupe order.
    /// - Parameter source: A short tag describing what triggered the reload.
    public func reload(source: String) {
        guard let environment else {
            onReload?(source, 0)
            return
        }

        var seenStores = Set<ObjectIdentifier>()
        for store in environment.reloadableConfigStores {
            let identifier = ObjectIdentifier(store)
            guard seenStores.insert(identifier).inserted else { continue }
            store.loadAll()
        }
        environment.refreshWindowTitlesAfterConfigReload()
        onReload?(source, seenStores.count)
    }
}
