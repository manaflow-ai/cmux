public import CmuxNextSettings
public import Foundation

/// What a page call carries besides its op and params. The host fills it, never the page.
public nonisolated struct PageCallContext: Sendable, Hashable {
    /// The page id (`cmux.history`).
    public let page: String
    /// `page` for every call a page makes (the host refuses an `origin` the page sends); `user`
    /// only together with ``confirmed``, after a person approved the call on a native sheet.
    public let origin: String
    /// True after a person approved this call on a native confirmation sheet
    /// (``ConfirmingPageProvider``). Only then may a provider tell an owner the call is the user's
    /// own gesture (for example top-level `origin: "user"` on an app-supervisor command).
    public let confirmed: Bool
    /// The page's operation id (decision 31, zero-latency.md): the same on a resend after a
    /// reconnect, so an owner can apply the call once. Checked by the router (1-128 characters of
    /// `[A-Za-z0-9._:-]`); nil when the page sent none.
    public let opid: String?
    /// A real key or mouse event reached the page's view within the last second (the host's
    /// record, never the page's word): the call is backed by the person's gesture. Only a provider
    /// that serves the app's own trusted UI (the bundled Settings page) may treat that as the user.
    public let userGesture: Bool

    /// The user's own call: approved on a native sheet. Nothing a page sends can make this true.
    public var isConfirmedUser: Bool { origin == "user" && confirmed }

    public init(page: String, origin: String = "page", confirmed: Bool = false, opid: String? = nil, userGesture: Bool = false) {
        self.page = page
        self.origin = origin
        self.confirmed = confirmed
        self.opid = opid
        self.userGesture = userGesture
    }

    /// Whether `text` is a valid operation id: 1-128 characters of `[A-Za-z0-9._:-]`.
    public static func isValidOpid(_ text: String) -> Bool {
        (1...128).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".:_-".contains($0)) }
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
    /// The person declined the native confirmation.
    public static let cancelled = PageError(code: "cmux.page.cancelled", message: "cancelled")
    public static func unavailable(_ message: String) -> PageError {
        PageError(code: "cmux.protocol.unavailable", message: message, retryable: true)
    }
    /// The link to the owner (or the page) is gone (the Settings lead's page pattern).
    public static let closed = PageError(code: "cmux.protocol.closed", message: "the link to the owner is closed", retryable: true)
}
