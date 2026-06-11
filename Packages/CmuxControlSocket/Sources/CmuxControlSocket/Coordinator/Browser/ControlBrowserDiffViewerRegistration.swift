/// The outcome of the legacy `v2RegisterDiffViewerURLIfNeeded` step of
/// `browser.open_split`. Each failure case maps onto exactly one legacy
/// `invalid_params` error shape.
public enum ControlBrowserDiffViewerRegistration: Sendable, Equatable {
    /// Not a diff-viewer URL (or no URL): nothing to register.
    case notApplicable
    /// The trusted allowlist registered successfully.
    case registered
    /// Token/files guard failed (legacy "Missing or invalid trusted diff
    /// viewer allowlist", `data: nil`).
    case missingOrInvalidAllowlist
    /// Some file entries were invalid (legacy "Invalid trusted diff viewer
    /// allowlist", `data: nil`).
    case invalidAllowlist
    /// Registration threw (legacy "Invalid trusted diff viewer allowlist",
    /// `data: {"details": …}`).
    case invalidAllowlistDetails(String)
}
