public import CmuxNextSettings
public import Foundation

/// What a page call carries besides its op and params. The host fills it, never the page.
public nonisolated struct PageCallContext: Sendable, Hashable {
    /// The page id (`cmux.history`).
    public let page: String
    /// Always `user`: a page is a user surface, and the host refuses an `origin` the page sends.
    public let origin: String

    public init(page: String, origin: String = "user") {
        self.page = page
        self.origin = origin
    }
}

/// A refusal in the pane-protocol shape (`{t:"err", code, message, retryable, details?}`).
public nonisolated struct PageError: Error, Sendable, Equatable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let details: JSONValue?

    public init(code: String, message: String, retryable: Bool = false, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
    }

    public static func unknownOp(_ op: String) -> PageError { PageError(code: "cmux.protocol.unknown_op", message: op) }
    public static func invalidParams(_ message: String) -> PageError { PageError(code: "cmux.protocol.invalid_params", message: message) }
    public static func unavailable(_ message: String) -> PageError {
        PageError(code: "cmux.protocol.unavailable", message: message, retryable: true)
    }
}
