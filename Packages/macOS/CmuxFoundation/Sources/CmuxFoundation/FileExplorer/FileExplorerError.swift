/// An error surfaced by a file-explorer provider or its SSH transport.
///
/// A pure, `Sendable` value so it crosses the actor and task boundaries the SSH
/// provider and transport run on. The user-facing, localized `errorDescription`
/// (the `LocalizedError` conformance) lives in the app target, where
/// `String(localized:)` resolves against the app bundle's string catalog; the
/// package only owns the case shape that provider/transport code throws.
public enum FileExplorerError: Error, Sendable {
    /// The provider is not currently able to serve listings.
    case providerUnavailable
    /// An SSH command failed; the associated value carries the captured stderr.
    case sshCommandFailed(String)
}
