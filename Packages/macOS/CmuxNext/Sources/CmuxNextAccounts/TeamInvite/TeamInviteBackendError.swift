/// A refused or failed cmux.com call: its error code passes through to the caller.
public nonisolated struct TeamInviteBackendError: Error, Sendable, Equatable {
    /// The cmux.com or transport code (`not_signed_in`, `forbidden`, `http_503`).
    public var code: String
    /// A readable message.
    public var message: String

    /// Creates an error.
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
