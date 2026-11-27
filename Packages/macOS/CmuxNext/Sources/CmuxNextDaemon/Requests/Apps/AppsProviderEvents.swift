import Foundation

/// Event `apps-provider-request`: the supervisor routes one app call to this
/// connection's registered family. Answer it with ``AppsProviderResultRequest``
/// before `deadlineMs`.
public struct AppsProviderCall: Sendable, Equatable {
    public static let eventName = "apps-provider-request"

    public let requestID: UInt64
    public let app: String
    public let origin: String
    public let op: String
    public let params: JSONValue
    public let idempotencyKey: String?
    public let deadlineMs: UInt64?

    public init(requestID: UInt64, app: String, origin: String, op: String, params: JSONValue,
                idempotencyKey: String? = nil, deadlineMs: UInt64? = nil) {
        self.requestID = requestID
        self.app = app
        self.origin = origin
        self.op = op
        self.params = params
        self.idempotencyKey = idempotencyKey
        self.deadlineMs = deadlineMs
    }

    /// The provider call in `event`, or nil.
    public init?(_ event: DaemonEvent) {
        guard case .unknown(Self.eventName, let payload) = event,
              let id = payload["request_id"]?.doubleValue.flatMap({ UInt64(exactly: $0) }),
              let op = payload["op"]?.stringValue else { return nil }
        self.init(requestID: id, app: payload["app"]?.stringValue ?? "", origin: payload["origin"]?.stringValue ?? "script",
                  op: op, params: payload["params"] ?? .object([:]), idempotencyKey: payload["idempotency_key"]?.stringValue,
                  deadlineMs: payload["deadline_ms"]?.doubleValue.flatMap { UInt64(exactly: $0) })
    }
}

/// Event `apps-provider-cancel`: the call ended on the daemon side
/// (`timeout`, `revoked`, `host_exited`); its answer is no longer read.
public struct AppsProviderCancel: Sendable, Equatable {
    public static let eventName = "apps-provider-cancel"

    public let requestID: UInt64
    public let reason: String

    public init(requestID: UInt64, reason: String) {
        self.requestID = requestID
        self.reason = reason
    }

    public init?(_ event: DaemonEvent) {
        guard case .unknown(Self.eventName, let payload) = event,
              let id = payload["request_id"]?.doubleValue.flatMap({ UInt64(exactly: $0) }) else { return nil }
        self.init(requestID: id, reason: payload["reason"]?.stringValue ?? "")
    }
}
