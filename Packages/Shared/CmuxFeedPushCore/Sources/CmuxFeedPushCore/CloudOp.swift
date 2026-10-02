import Foundation

/// One `POST /v1/ops` body for the API Worker: a typed op with a
/// client-chosen idempotency key (a retry reuses the key; a new user action
/// makes a new key).
public struct CloudOp: Sendable {
    public var op: String
    public var params: [String: JSONValue]
    public var idempotencyKey: String
    public var origin: String

    public init(op: String, params: [String: JSONValue], idempotencyKey: String, origin: String) {
        self.op = op
        self.params = params
        self.idempotencyKey = idempotencyKey
        self.origin = origin
    }

    public enum APNsEnvironment: String, Sendable { case development, production }

    /// Registers this install's APNs token on the user's account (one per install).
    public static func registerPushTarget(token: Data, topic: String, environment: APNsEnvironment,
                                          deviceName: String, idempotencyKey: String) -> CloudOp {
        CloudOp(op: "push.target.register",
                params: ["token": .string(token.hexString), "topic": .string(topic),
                         "environment": .string(environment.rawValue), "device_name": .string(deviceName)],
                idempotencyKey: idempotencyKey, origin: "cli")
    }

    /// Removes the token (sign-out, notifications turned off).
    public static func removePushTarget(token: Data, idempotencyKey: String) -> CloudOp {
        CloudOp(op: "push.target.remove", params: ["token": .string(token.hexString)],
                idempotencyKey: idempotencyKey, origin: "cli")
    }

    /// Answers a feed item from a banner action. The user acted: origin `user`.
    public static func answer(item: String, answer: FeedAnswer, idempotencyKey: String) -> CloudOp {
        CloudOp(op: "feed.answer", params: ["item": .string(item), "answer": answer.value],
                idempotencyKey: idempotencyKey, origin: "user")
    }

    /// The JSON request body.
    public func body() throws -> Data {
        let object: [String: Any] = ["op": op, "params": params.mapValues(\.foundation),
                                     "idempotency_key": idempotencyKey, "origin": origin]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

extension Data {
    /// Lowercase hex, the APNs device-token spelling.
    public var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

/// A JSON value that is Sendable (op params cross actors).
public enum JSONValue: Hashable, Sendable {
    case string(String)
    case bool(Bool)
    case object([String: JSONValue])

    var foundation: Any {
        switch self {
        case .string(let value): value
        case .bool(let value): value
        case .object(let value): value.mapValues(\.foundation)
        }
    }
}
