/// Typed reason a hosted sidebar extension's connection is blocked.
///
/// Returned by ``CMUXSidebarExtensionHostXPC`` through its `onManifestBlocked`
/// seam (in place of the former free-form `String?`). The app target maps each
/// case to localized status/detail copy with `String(localized:)`, which stays
/// app-side so it binds to the app bundle's catalog rather than the package
/// bundle. `nil` (no value) means the extension is not blocked.
@_spi(CmuxHostTransport)
public enum CMUXSidebarExtensionBlockedReason: Sendable, Hashable {
    /// The XPC connection was interrupted after it had been established, so no
    /// workspace data or actions are being shared.
    case connectionInterrupted
    /// The extension process exposed no manifest-request entry point.
    case missingManifest
    /// The extension returned a manifest CMUX could not decode or validate.
    case invalidManifest
    /// The manifest request returned without a payload.
    case manifestRequestFailed
    /// The extension did not return its manifest within the request timeout.
    case manifestTimedOut
}
