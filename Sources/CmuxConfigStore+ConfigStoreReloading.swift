import CmuxTerminalCore

/// Lets `CmuxConfigStoreReloadCoordinator` drive per-window config reloads through a
/// protocol seam. `CmuxConfigStore`'s existing `loadAll()` already satisfies the
/// requirement, so this conformance is empty.
extension CmuxConfigStore: CmuxConfigStoreReloading {}
