import Foundation

// The provider channel of the app supervisor (plans/cmux-next/app-op-routing.md;
// cmux-tui-core `apps/provider.rs`): the Mac app serves the app ops that the
// daemon does not own (for example the `coderouter` family) for the apps the
// daemon runs. Registration needs the verified cmux app connection and ends
// with the connection.

/// `apps-provider-register {families}`: answers `{families}`. A family that
/// another live connection holds is refused (`apps.provider.taken`).
public struct AppsProviderRegisterRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "apps-provider-register"

    public var families: [String]

    public init(families: [String]) {
        self.families = families
    }
}

/// `apps-provider-result {request_id, ok, body}`: the answer to one
/// `apps-provider-request` event (ABI bodies: the value, or
/// `{code, message, details?, retryable}`).
public struct AppsProviderResultRequest: DaemonRequest, VerbatimFieldsRequest {
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
        case requestID = "requestId", ok
    }

    var verbatimFields: [String: JSONValue] { ["body": body] }
}
