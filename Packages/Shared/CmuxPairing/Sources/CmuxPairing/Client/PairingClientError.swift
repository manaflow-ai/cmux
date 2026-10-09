/// The owner refused a pairing op (`code` is the backend's, for example
/// `pairing.offer_used`), or its answer could not be decoded.
public struct PairingClientError: Error, Hashable, Sendable {
    public var code: String
    public var message: String
    public var retryable: Bool

    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}
