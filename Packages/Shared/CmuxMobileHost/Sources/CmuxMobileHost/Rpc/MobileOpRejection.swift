import CmuxMobileWire

/// An op refusal in the shared error shape.
public struct MobileOpRejection: Error, Hashable, Sendable {
    public var code: String
    public var message: String
    public var details: JSONValue?
    public var retryable: Bool

    public init(code: String, message: String, details: JSONValue? = nil, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.details = details
        self.retryable = retryable
    }
}
