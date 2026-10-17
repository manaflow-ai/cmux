public import Foundation
import CmuxNextDaemon

/// One `apps-provider-request` from the app supervisor (app-op-routing.md):
/// an app's call to an op the daemon does not own, already checked against
/// the app's scopes, grants and gesture tokens. The Mac answers it with its
/// owner handler (``AppHostCapabilities``) and replies with
/// `apps-provider-result`.
public nonisolated struct RoutedAppCall: Sendable, Equatable {
    public var requestID: UInt64
    public var app: String
    public var op: String
    public var params: AppJSON
    /// `user` inside a gesture, else `script` (the supervisor's stamp; any other value counts as `script`).
    public var origin: String

    /// Reads the event; nil when a field is missing.
    public init?(_ payload: AppJSON) {
        guard let id = payload["request_id"]?.numberValue.flatMap({ UInt64(exactly: $0) }), let app = payload["app"]?.stringValue,
              let op = payload["op"]?.stringValue else { return nil }
        requestID = id
        self.app = app
        self.op = op
        params = payload["params"] ?? .object([:])
        origin = payload["origin"]?.stringValue == "user" ? "user" : "script"
    }

    /// The `{ok, body}` of the answer: the ABI result body `{value}` around
    /// the handler's value, or the ABI error body `{code, message,
    /// retryable, details?}` (an op without a handler is
    /// `operation.unsupported`). The app's `cmux.call` resolves to
    /// `body.value` and the daemon passes an object body through as is, so a
    /// bare object answer resolved every Mac-side op to `undefined` (the
    /// CodeRouter page stayed on "Loading…").
    public func answer(with capabilities: AppHostCapabilities) async -> (ok: Bool, body: AppJSON) {
        let ok: Bool, body: AppJSON // one return: swiftlang/swift#92698 drops `ok` at -O (cx-21wc5)
        do throws(AppHostCapabilityError) {
            let value = try await capabilities.handle(AppHostCapabilityRequest(app: app, op: op, params: params, origin: origin))
            (ok, body) = (true, .object(["value": value]))
        } catch {
            (ok, body) = (false, Self.errorBody(code: error.code, message: error.message, retryable: error.retryable, details: error.details))
        }
        return (ok, body)
    }

    /// The answer while an administrator turned apps off on this Mac.
    public static func disabledAnswer(_ reason: String) -> (ok: Bool, body: AppJSON) {
        (false, errorBody(code: "apps.disabled", message: reason, retryable: false, details: nil))
    }

    public static func errorBody(code: String, message: String, retryable: Bool, details: AppJSON?) -> AppJSON {
        var body: [String: AppJSON] = ["code": .string(code), "message": .string(message), "retryable": .bool(retryable)]
        if let details { body["details"] = details }
        return .object(body)
    }
}
