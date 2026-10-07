/// A daemon refusal or failure in the shared error shape.
public struct MobileDaemonError: Error, Hashable, Sendable {
    public var code: String
    public var message: String
    public var retryable: Bool

    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}
