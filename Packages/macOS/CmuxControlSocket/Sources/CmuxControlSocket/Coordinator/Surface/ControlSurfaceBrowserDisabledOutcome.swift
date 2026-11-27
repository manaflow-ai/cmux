public import Foundation

/// The outcome of the legacy `v2BrowserDisabledExternalOpenResult`, shared by
/// `surface.split` and `surface.create` when a browser surface is requested while
/// the cmux browser is disabled.
///
/// Each case maps byte-for-byte onto the legacy result the helper produced. The
/// `openedExternally` payload carries the enclosing window (the only resolved id;
/// the workspace/pane/surface fields are all `null` in the legacy payload).
public enum ControlSurfaceBrowserDisabledOutcome: Sendable, Equatable {
    /// A `url` param was present but did not parse (legacy `invalid_params` /
    /// "Invalid URL", `data: {"url": rawURL}`).
    case invalidURL(rawURL: String)
    /// No `url` param at all (legacy `browser_disabled` / "cmux browser is
    /// disabled", `data: nil`).
    case noURL
    /// `NSWorkspace.open` failed (legacy `external_open_failed` / "Failed to open
    /// URL externally", `data: {"url": …}`).
    case externalOpenFailed(url: String)
    /// The URL opened externally (legacy `.ok` with the `external_browser_disabled`
    /// placement payload). Carries the enclosing window and the opened URL.
    case openedExternally(windowID: UUID?, url: String)
}
