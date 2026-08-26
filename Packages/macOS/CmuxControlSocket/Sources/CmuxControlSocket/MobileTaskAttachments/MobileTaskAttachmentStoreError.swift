/// A wire-ready mobile task attachment storage failure.
public struct MobileTaskAttachmentStoreError: Error, Equatable, Sendable {
    /// RPC error code.
    public let code: String
    /// Human-readable error message.
    public let message: String

    /// Creates a wire-ready attachment error.
    ///
    /// - Parameters:
    ///   - code: RPC error code.
    ///   - message: Human-readable error message.
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
