public import Foundation

/// The outcome of `browser.dialog.accept` / `browser.dialog.dismiss`, the typed
/// twin of the legacy `TerminalController.v2BrowserDialogRespond(params:accept:)`
/// body.
///
/// The witness reproduces the `v2BrowserWithPanel` head, installs the dialog
/// telemetry + dialog hooks, then runs the page JS that shifts the front entry
/// off the in-page `__cmuxDialogQueue` and records the chosen default. When the
/// queue is empty (or the JS reports `ok: false`), it returns ``notFound`` with
/// the current pending-dialog snapshot (so the coordinator can echo it as the
/// `pending` data); otherwise it returns ``resolved`` with the normalized
/// shifted `dialog` entry and the `remaining` count.
///
/// The `accepted` flag in the payload is the `accept` argument the coordinator
/// already knows, so it is not carried back here.
public enum ControlBrowserDialogRespondResolution: Sendable, Equatable {
    /// Panel resolution failed.
    case failed(ControlBrowserPanelResolutionFailure)
    /// The dialog-response JavaScript failed (`js_error` / the JS error message).
    case jsError(message: String)
    /// No pending dialog (`not_found` / "No pending dialog",
    /// data `{"pending": <queue snapshot>}`). `pending` is the per-surface
    /// pending-dialog snapshot as wire values (the legacy
    /// `v2BrowserPendingDialogs(surfaceId:)` result).
    case notFound(pending: [JSONValue])
    /// Resolved: the owning workspace, the resolved surface, the normalized
    /// shifted dialog entry, and the remaining queue length as a wire value
    /// (carried as ``JSONValue`` — not `Int?` — so the legacy `NSNumber`
    /// integer-vs-double round-trip is preserved exactly; absent → `.null`,
    /// matching the legacy `v2OrNull(dict["remaining"])`).
    case resolved(
        workspaceID: UUID,
        surfaceID: UUID,
        dialog: JSONValue,
        remaining: JSONValue
    )
}
