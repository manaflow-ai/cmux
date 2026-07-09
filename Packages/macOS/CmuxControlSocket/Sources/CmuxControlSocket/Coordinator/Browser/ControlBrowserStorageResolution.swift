public import Foundation

/// The outcome of `browser.storage.get`, the typed twin of the legacy
/// `TerminalController.v2BrowserStorageGet(params:)` body.
///
/// The witness computes the `storageType` (the legacy
/// `BrowserControlService.storageType(params:)`, which lives in the app-side
/// substrate), resolves the panel, runs the storage-read JS, and normalizes the
/// value. The coordinator shapes the identity payload plus `type`/`key`/`value`.
/// `storageType` is carried back because the legacy payload echoes it.
public enum ControlBrowserStorageGetResolution: Sendable, Equatable {
    /// Panel resolution failed.
    case failed(ControlBrowserPanelResolutionFailure)
    /// The storage-read JavaScript failed (`js_error` / the JS error message).
    case jsError(message: String)
    /// The storage object was unavailable (`invalid_state` / "Storage
    /// unavailable", data `{"type": storageType}`).
    case unavailable(storageType: String)
    /// Resolved: the owning workspace, the resolved surface, the storage type,
    /// the queried key (`nil` → JSON `null`), and the normalized value.
    case resolved(
        workspaceID: UUID,
        surfaceID: UUID,
        storageType: String,
        key: String?,
        value: JSONValue
    )
}

/// The outcome of `browser.storage.set`, the typed twin of the legacy
/// `TerminalController.v2BrowserStorageSet(params:)` body. The `Missing key` /
/// `Missing value` param errors are emitted by the coordinator before the
/// witness runs.
public enum ControlBrowserStorageSetResolution: Sendable, Equatable {
    /// Panel resolution failed.
    case failed(ControlBrowserPanelResolutionFailure)
    /// The storage-write JavaScript failed (`js_error` / the JS error message).
    case jsError(message: String)
    /// The storage object was unavailable (`invalid_state` / "Storage
    /// unavailable", data `{"type": storageType}`).
    case unavailable(storageType: String)
    /// Resolved: the owning workspace, the resolved surface, the storage type,
    /// and the written key.
    case resolved(workspaceID: UUID, surfaceID: UUID, storageType: String, key: String)
}

/// The outcome of `browser.storage.clear`, the typed twin of the legacy
/// `TerminalController.v2BrowserStorageClear(params:)` body.
public enum ControlBrowserStorageClearResolution: Sendable, Equatable {
    /// Panel resolution failed.
    case failed(ControlBrowserPanelResolutionFailure)
    /// The storage-clear JavaScript failed (`js_error` / the JS error message).
    case jsError(message: String)
    /// The storage object was unavailable (`invalid_state` / "Storage
    /// unavailable", data `{"type": storageType}`).
    case unavailable(storageType: String)
    /// Resolved: the owning workspace, the resolved surface, and the storage
    /// type.
    case resolved(workspaceID: UUID, surfaceID: UUID, storageType: String)
}
