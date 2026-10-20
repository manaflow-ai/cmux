/// Failures while uploading files dropped onto a remote terminal surface.
///
/// `LocalizedError` conformance lives in the app target so the user-facing
/// strings resolve against the app bundle's localization tables.
public enum RemoteDropUploadError: Error, Sendable {
    /// No connected remote session can accept the upload.
    case unavailable
    /// The dropped item did not carry a usable file URL.
    case invalidFileURL
    /// The transfer ran and failed; the payload is the transport's detail text.
    case uploadFailed(String)
}
