/// Errors raised while decoding a Cloud VM attach endpoint.
public enum CmxCloudAttachError: Error, Equatable, Sendable {
    /// The endpoint declared a transport this client cannot dial.
    ///
    /// iOS cloud attach only speaks the cmuxd-remote WebSocket; the SSH endpoint
    /// is a provider fallback and is not usable from the phone.
    case unsupportedTransport(String)
}
