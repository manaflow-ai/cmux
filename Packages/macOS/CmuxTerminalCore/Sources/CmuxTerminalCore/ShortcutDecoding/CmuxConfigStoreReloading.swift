/// A per-window cmux configuration store that can re-read its backing file.
///
/// The app target's `CmuxConfigStore` conforms to this so
/// `CmuxConfigStoreReloadCoordinator` can drive reloads without depending on the
/// concrete app type. It is `AnyObject` so the coordinator can dedupe stores shared
/// across windows by object identity, matching the original
/// `Set<ObjectIdentifier>` logic.
@MainActor
public protocol CmuxConfigStoreReloading: AnyObject {
    /// Re-reads the configuration from its backing source.
    func loadAll()
}

/// Supplies the live set of per-window configuration stores and refreshes window
/// chrome after a reload.
///
/// The app target's delegate conforms to this, exposing its `mainWindowContexts`
/// stores and its `refreshWindowTitlesAcrossMainWindows()` behavior behind a
/// read-only seam so the coordinator never reaches into window or context state.
@MainActor
public protocol CmuxConfigStoreReloadEnvironment: AnyObject {
    /// The configuration stores across all open main windows, in iteration order.
    ///
    /// May contain the same store more than once when windows share a store; the
    /// coordinator dedupes by object identity.
    var reloadableConfigStores: [any CmuxConfigStoreReloading] { get }

    /// Refreshes window titles across all main windows after stores reload.
    func refreshWindowTitlesAfterConfigReload()
}
