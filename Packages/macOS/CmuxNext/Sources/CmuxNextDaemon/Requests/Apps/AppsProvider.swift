import Foundation

/// `apps-provider-register`: this connection serves app ops of `families`
/// that the daemon does not own (cmux-tui-core `apps/provider.rs`,
/// plans/cmux-next/app-op-routing.md). Only the verified cmux app
/// connection may register (`client-hello` `user_origin_allowed`); the
/// registration ends with the connection.
public struct AppsProviderRegisterRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "apps-provider-register"

    public var families: [String]

    public init(families: [String]) {
        self.families = families
    }
}

/// `apps-provider-result`: the answer to one ``AppsProviderCall``. `body`
/// is the op's ABI body: on success the result object (`{value, revision?,
/// replayed?}` for `credential.relay`), on failure `{code, message,
/// retryable, details?}`.
public struct AppsProviderResultRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "apps-provider-result"

    public var requestID: UInt64
    public var ok: Bool
    public var body: JSONValue

    public init(requestID: UInt64, ok: Bool, body: JSONValue) {
        self.requestID = requestID
        self.ok = ok
        self.body = body
    }

    enum CodingKeys: String, CodingKey {
        case requestID, ok
    }
}

extension AppsProviderResultRequest: VerbatimFieldsRequest {
    var verbatimFields: [String: JSONValue] { ["body": body] }
}
