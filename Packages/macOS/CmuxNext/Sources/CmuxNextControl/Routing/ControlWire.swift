public import CmuxNextSettings
import Foundation

/// A decoded v2 request line: `{"id": …, "method": "…", "params": {…}}`,
/// the framing the old app's control socket and the `cmux` CLI use.
public struct ControlRequest: Sendable {
    public var id: JSONValue?
    public var method: String
    public var params: [String: JSONValue]

    public init(id: JSONValue? = nil, method: String, params: [String: JSONValue] = [:]) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// A protocol-level failure, encoded as `{"ok": false, "error": {…}}`.
public struct ControlError: Error, Sendable, Hashable {
    public var code: String
    public var message: String
    public var data: JSONValue?

    public init(code: String, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static func invalidParams(_ message: String, data: JSONValue? = nil) -> ControlError {
        ControlError(code: "invalid_params", message: message, data: data)
    }

    /// The request's deadline passed before it was answered. A main-actor
    /// request that times out while still queued never runs.
    public static func timeout(_ method: String, after duration: Duration) -> ControlError {
        ControlError(code: "timeout", message: ControlStrings.format("control.error.timeout", "%1$@ did not finish within %2$@", method, duration.formattedMilliseconds),
                     data: ["method": .string(method), "deadline_ms": JSONValue(duration.wholeMilliseconds)])
    }

    /// The main-actor work queue is full. The request did not run; retry later.
    public static func busy(pending: Int, limit: Int) -> ControlError {
        ControlError(code: "busy", message: ControlStrings.format("control.error.busy", "cmux is busy (%1$lld queued requests, limit %2$lld); retry later", pending, limit),
                     data: ["pending": JSONValue(pending), "limit": JSONValue(limit)])
    }
}

/// JSON Lines framing shared by the router and the connection.
enum ControlWire {
    static func decode(_ line: String) -> Result<ControlRequest, ControlError> {
        guard let value = try? JSONValue.parse(Data(line.utf8)) else {
            return .failure(ControlError(code: "parse_error", message: ControlStrings.text("control.error.invalidJSON", "Invalid JSON")))
        }
        guard case .object(let members) = value else {
            return .failure(ControlError(code: "invalid_request", message: ControlStrings.text("control.error.expectedJSONObject", "Expected JSON object")))
        }
        let method = members["method"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !method.isEmpty else {
            return .failure(ControlError(code: "invalid_request", message: ControlStrings.text("control.error.missingMethod", "Missing method")))
        }
        return .success(ControlRequest(id: members["id"], method: method, params: members["params"]?.objectValue ?? [:]))
    }

    static func encode(id: JSONValue?, result: Result<JSONValue, ControlError>) -> String {
        switch result {
        case .success(let value):
            return JSONValue.object(["id": id ?? .null, "ok": .bool(true), "result": value]).compactText
        case .failure(let error):
            return encode(id: id, error: error)
        }
    }

    static func encode(id: JSONValue?, error: ControlError) -> String {
        var body: [String: JSONValue] = ["code": .string(error.code), "message": .string(error.message)]
        if let data = error.data { body["data"] = data }
        return JSONValue.object(["id": id ?? .null, "ok": .bool(false), "error": .object(body)]).compactText
    }
}

extension Duration {
    var wholeMilliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1_000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    var fractionalMilliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    var formattedMilliseconds: String { "\(wholeMilliseconds) ms" }
}
