/// A parsed bridge message: the requested operation plus the still-encoded JSON
/// payload string (decoded lazily into the matching request model).
public struct BrowserWebAuthnMessageEnvelope {
    /// The requested bridge operation.
    public let kind: BrowserWebAuthnBridgeMessageKind
    /// The raw JSON payload string, if any was supplied.
    public let payloadJSON: String?
}
