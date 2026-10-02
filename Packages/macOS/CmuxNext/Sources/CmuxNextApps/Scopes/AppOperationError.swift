/// A refused or failed app op: `{code, message, details?, retryable}` (spec
/// 6.2). The app supervisor in the daemon produces these for apps; the
/// client keeps the shape for the permission policy and its tests.
public nonisolated struct AppOperationError: Error, Sendable, Hashable {
    public var code: String
    public var message: String
    public var details: AppJSON?
    public var retryable: Bool

    public init(code: String, message: String, details: AppJSON? = nil, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.details = details
        self.retryable = retryable
    }

    public static func unsupported(_ op: String) -> AppOperationError {
        AppOperationError(code: "operation.unsupported", message: "\(op) is not supported by this host yet", details: ["op": .string(op)])
    }
}
