public import Foundation

/// The outcome of `browser.console.list` / `browser.console.clear`, the typed
/// twin of the legacy `TerminalController.v2BrowserConsoleList(params:)` body
/// (`browser.console.clear` reuses it with `clear=true` injected by the
/// coordinator).
///
/// The witness reproduces the `v2BrowserWithPanel` head, installs the telemetry
/// hooks, and evaluates the console-log read/clear script; the coordinator shapes
/// the identity payload plus the `entries` array and its `count`.
public enum ControlBrowserConsoleListResolution: Sendable, Equatable {
    /// Panel resolution failed.
    case failed(ControlBrowserPanelResolutionFailure)
    /// The console-log read/clear script failed (`js_error` / the JS error
    /// message).
    case jsError(message: String)
    /// Resolved: the owning workspace, the resolved surface, and the normalized
    /// console entries (the legacy `items.map(v2NormalizeJSValue)`).
    case resolved(workspaceID: UUID, surfaceID: UUID, entries: [JSONValue])
}

/// The outcome of `browser.errors.list`, the typed twin of the legacy
/// `TerminalController.v2BrowserErrorsList(params:)` body.
///
/// The witness reproduces the `v2BrowserWithPanel` head, installs the telemetry
/// hooks, and evaluates the error-log read/clear script; the coordinator shapes
/// the identity payload plus the `errors` array and its `count`.
public enum ControlBrowserErrorsListResolution: Sendable, Equatable {
    /// Panel resolution failed.
    case failed(ControlBrowserPanelResolutionFailure)
    /// The error-log read/clear script failed (`js_error` / the JS error
    /// message).
    case jsError(message: String)
    /// Resolved: the owning workspace, the resolved surface, and the normalized
    /// error entries (the legacy `items.map(v2NormalizeJSValue)`).
    case resolved(workspaceID: UUID, surfaceID: UUID, errors: [JSONValue])
}

/// The outcome of `browser.state.save`, the typed twin of the legacy
/// `TerminalController.v2BrowserStateSave(params:)` body.
///
/// The `Missing path` param error is emitted by the coordinator before the
/// witness runs. The witness reproduces the `v2BrowserWithPanel` head, reads
/// `localStorage`/`sessionStorage` + cookies + the per-surface frame selector,
/// and writes the JSON state file. The coordinator shapes the identity payload
/// plus the `path`/`cookies` keys and maps each failure category to its exact
/// legacy `.err`.
public enum ControlBrowserStateSaveResolution: Sendable, Equatable {
    /// Panel resolution failed.
    case failed(ControlBrowserPanelResolutionFailure)
    /// The storage-read script failed (`js_error` / the JS error message).
    case jsError(message: String)
    /// The state file could not be written (`internal_error` / "Failed to write
    /// state file", data `{"path": <path>, "error": <localizedDescription>}`).
    case writeFailed(path: String, error: String)
    /// Resolved: the owning workspace, the resolved surface, the written `path`,
    /// and the number of saved cookies.
    case resolved(workspaceID: UUID, surfaceID: UUID, path: String, cookieCount: Int)
}

/// The outcome of `browser.state.load`, the typed twin of the legacy
/// `TerminalController.v2BrowserStateLoad(params:)` body.
///
/// The `Missing path` param error is emitted by the coordinator before the
/// witness runs. The witness reads + parses the state file (its read/parse
/// failures precede panel resolution in the legacy body), reproduces the
/// `v2BrowserWithPanel` head, restores the frame selector / navigation / cookies
/// / storage, and reports success. The coordinator shapes the identity payload
/// plus the `path`/`loaded` keys and maps each failure category to its exact
/// legacy `.err`.
public enum ControlBrowserStateLoadResolution: Sendable, Equatable {
    /// The state file is not a JSON object (`invalid_params` / "State file must
    /// contain a JSON object", data `{"path": <path>}`).
    case notObject(path: String)
    /// The state file could not be read (`not_found` / "Failed to read state
    /// file", data `{"path": <path>, "error": <localizedDescription>}`).
    case readFailed(path: String, error: String)
    /// Panel resolution failed (after the file was read successfully).
    case failed(ControlBrowserPanelResolutionFailure)
    /// Resolved: the owning workspace, the resolved surface, and the loaded
    /// `path`.
    case resolved(workspaceID: UUID, surfaceID: UUID, path: String)
}
