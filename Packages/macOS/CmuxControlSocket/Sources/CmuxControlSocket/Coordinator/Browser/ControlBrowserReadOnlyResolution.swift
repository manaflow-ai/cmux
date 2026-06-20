public import Foundation

/// The outcome of `browser.get.title`, the typed twin of the legacy
/// `TerminalController.v2BrowserGetTitle(params:)` body.
///
/// The witness reproduces the `v2BrowserWithPanel` head and reads the resolved
/// browser panel's `pageTitle`; the coordinator shapes the identity payload plus
/// the `title` key.
public enum ControlBrowserGetTitleResolution: Sendable, Equatable {
    /// Panel resolution failed.
    case failed(ControlBrowserPanelResolutionFailure)
    /// Resolved: the owning workspace, the resolved surface, and the page title.
    case resolved(workspaceID: UUID, surfaceID: UUID, title: String)
}

/// The outcome of `browser.frame.select`, the typed twin of the legacy
/// `TerminalController.v2BrowserFrameSelect(params:)` body.
///
/// The `Missing selector` param error is emitted by the coordinator before the
/// witness runs. The witness reproduces the `v2BrowserWithPanel` head, resolves
/// the (possibly `@e`-ref) selector against the surface, evaluates the
/// same-origin iframe probe, and on success records the per-surface frame
/// selector. The coordinator shapes the identity payload plus `frame_selector`
/// and maps each non-success category to its exact legacy `.err`.
public enum ControlBrowserFrameSelectResolution: Sendable, Equatable {
    /// Panel resolution failed.
    case failed(ControlBrowserPanelResolutionFailure)
    /// The selector did not resolve to a known element ref for the surface
    /// (`not_found` / "Element reference not found", data `{"selector": <raw>}`).
    case elementRefNotFound(rawSelector: String)
    /// The iframe probe script failed (`js_error` / the JS error message).
    case jsError(message: String)
    /// The iframe is cross-origin (`not_supported` / "Cross-origin iframe
    /// control is not supported", data `{"selector": <resolved>}`).
    case crossOrigin(selector: String)
    /// The frame element was not found by the probe (`not_found` / "Frame not
    /// found", data `{"selector": <resolved>}`).
    case frameNotFound(selector: String)
    /// Resolved: the owning workspace, the resolved surface, and the recorded
    /// frame selector.
    case selected(workspaceID: UUID, surfaceID: UUID, frameSelector: String)
}

/// The outcome of `browser.frame.main`, the typed twin of the legacy
/// `TerminalController.v2BrowserFrameMain(params:)` body.
///
/// The witness reproduces the `v2BrowserWithPanel` head and clears the
/// per-surface frame selector; the coordinator shapes the identity payload with
/// a JSON-null `frame_selector` (the legacy `NSNull()`).
public enum ControlBrowserFrameMainResolution: Sendable, Equatable {
    /// Panel resolution failed.
    case failed(ControlBrowserPanelResolutionFailure)
    /// Resolved: the owning workspace and the resolved surface (the frame
    /// selector has been cleared).
    case resolved(workspaceID: UUID, surfaceID: UUID)
}

/// The outcome of `browser.screenshot`, the typed twin of the legacy
/// `TerminalController.v2BrowserScreenshot(params:)` body.
///
/// The witness reproduces the (inline) `v2BrowserWithPanel`-equivalent head,
/// captures the automation-visible viewport snapshot (15s budget), encodes the
/// PNG, and best-effort writes a temp file. The coordinator shapes the identity
/// payload plus `png_base64` and the optional `path`/`url` keys; it maps the
/// timeout and capture-failure categories to their exact legacy `.err`.
public enum ControlBrowserScreenshotResolution: Sendable, Equatable {
    /// Panel resolution failed.
    case failed(ControlBrowserPanelResolutionFailure)
    /// The snapshot capture timed out (`timeout` / "Timed out waiting for
    /// snapshot").
    case timedOut
    /// The snapshot could not be captured/encoded (`internal_error` / "Failed
    /// to capture snapshot").
    case captureFailed
    /// Resolved: the owning workspace, the resolved surface, the base64 PNG, and
    /// the optional temp-file `path`/`url` (both present or both absent).
    case resolved(
        workspaceID: UUID,
        surfaceID: UUID,
        pngBase64: String,
        filePath: String?,
        fileURL: String?
    )
}
