/// Why an RFB session failed.
public enum RfbError: Error, Hashable, Sendable {
    /// The peer's first bytes were not an RFB ProtocolVersion.
    case notRfb
    case unsupportedVersion(String)
    /// The server refused the connection (with its reason).
    case refused(String)
    /// No offered security type is one this client speaks (None, VNC authentication).
    case authUnsupported([UInt8])
    /// VNC authentication was needed and no password came.
    case passwordMissing
    case authFailed(String)
    case protocolError(String)
    case closed
}
