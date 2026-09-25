public struct BrowserWebAuthnMessageEnvelope {
    public let kind: BrowserWebAuthnBridgeMessageKind
    public let payloadJSON: String?

    public init(
        kind: BrowserWebAuthnBridgeMessageKind,
        payloadJSON: String?
    ) {
        self.kind = kind
        self.payloadJSON = payloadJSON
    }
}
