/// An app ABI refusal or failure returned by a capability owner.
public nonisolated struct AppHostCapabilityError: Error, Sendable {
    /// The stable app ABI code, such as `operation.unsupported` or an owner's code.
    public var code: String
    /// The owner's explanation of the refusal or failure.
    public var message: String
    /// Whether the caller can retry without changing the request.
    public var retryable: Bool
    /// Optional structured details; never credentials or private command output.
    public var details: AppJSON?

    /// Creates an owner failure for the app ABI result envelope.
    /// - Parameters:
    ///   - code: A stable machine-readable code.
    ///   - message: The owner's explanation.
    ///   - retryable: False unless the owner knows a retry is useful.
    ///   - details: Optional non-secret structured details, absent by default.
    public init(code: String, message: String, retryable: Bool = false, details: AppJSON? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
    }

    /// Refuses an operation for which the owner has no implementation.
    /// - Parameter op: The full operation name.
    /// - Returns: The app ABI's unsupported-operation error.
    public static func unsupported(_ op: String) -> AppHostCapabilityError {
        AppHostCapabilityError(code: "operation.unsupported", message: "\(op) is not available in this build", details: ["op": .string(op)])
    }
}
