/// A GUI RPC error mapped from the transport envelope's error object.
public struct GuiWireError: Codable, Error, Hashable, Sendable {
    /// The fail-open machine-readable error code.
    public let code: GuiWireErrorCode
    /// The server-provided message passed through unchanged.
    public let message: String

    /// Creates a wire error from a typed code.
    /// - Parameters:
    ///   - code: The typed, fail-open error code.
    ///   - message: The server-provided message.
    public init(code: GuiWireErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    /// Maps an RPC envelope error object into the wire error taxonomy.
    /// - Parameters:
    ///   - code: The raw open code from the RPC envelope.
    ///   - message: The message from the RPC envelope.
    public init(code: String, message: String) {
        self.init(code: GuiWireErrorCode(rawValue: code), message: message)
    }
}
