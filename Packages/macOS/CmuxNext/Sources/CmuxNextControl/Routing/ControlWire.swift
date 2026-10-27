public import CmuxNextSettings
import Foundation

/// A decoded v2 request line: `{"id": …, "method": "…", "params": {…}}`,
/// the framing the old app's control socket and the `cmux` CLI use.
public struct ControlRequest: Sendable {
    public var id: JSONValue?
    public var method: String
    public var params: [String: JSONValue]
    /// In-process provider attribution; wire decoding never accepts this field.
    /// An app's user gesture does not turn its principal into the native frontend.
    public var callerApp: String?
    /// The caller's flow id (the top-level `flow` the `cmux` CLI mints for each request, task 115): an integer from
    /// 1 to 2^53 - 1, so a JSON number holds it exactly. Nil when the line has none or has one of another shape; an
    /// app older than the field never reads it, so a CLI sends it to every app.
    public var flow: UInt64?
    /// Who the caller says it is (the top-level `source` the `cmux` CLI sends beside `flow`: `cli`, `mcp` or
    /// `agent`), for the trace and the latency histograms only: it grants nothing. Nil when the line has none or an
    /// unknown one; wire decoding never yields ``ControlRequestScope/Source/app``.
    public var source: ControlRequestScope.Source?
    /// The socket request's trace and latency scope (``ControlRequestScope``); nil for in-process callers. Wire
    /// decoding never sets it.
    public var scope: ControlRequestScope?

    public init(id: JSONValue? = nil, method: String, params: [String: JSONValue] = [:], callerApp: String? = nil,
                flow: UInt64? = nil, source: ControlRequestScope.Source? = nil) {
        self.id = id
        self.method = method
        self.params = params
        self.callerApp = callerApp
        self.flow = flow
        self.source = source
    }

    /// The request a handler makes on this one's behalf (`tab.focus`, `file.open` and `palette.run` run
    /// `action.run`): the same id, flow, source and scope, so the run it leads to keeps the caller's trace, its
    /// queued and dispatched marks and its flow at `action.commit` (task 115). The calling app is not carried: a
    /// derived request keeps the principal it had before.
    public func forwarded(method: String, params: [String: JSONValue]) -> ControlRequest {
        var request = ControlRequest(id: id, method: method, params: params, flow: flow, source: source)
        request.scope = scope
        return request
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

    /// `name` (an action or method) belongs to a feature an administrator
    /// turned off (`DisabledFeatures`).
    public static func featureDisabled(_ name: String, feature: String) -> ControlError {
        ControlError(code: "feature.disabled",
                     message: ControlStrings.format("control.error.featureDisabled", "%1$@ is turned off by your organization (%2$@)", name, feature),
                     data: ["action": .string(name), "feature": .string(feature)])
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

    /// A terminal-starting request missed the terminal start deadline. The
    /// daemon may still create the terminal, so the caller must not simply
    /// retry (`data.terminal_may_appear`).
    public static func terminalStartTimeout(_ method: String, after duration: Duration) -> ControlError {
        ControlError(code: "timeout", message: ControlStrings.format("control.error.terminalStartTimeout", "%1$@ did not finish within %2$@; the terminal may still appear", method, duration.formattedMilliseconds),
                     data: ["method": .string(method), "deadline_ms": JSONValue(duration.wholeMilliseconds), "terminal_may_appear": true])
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
        return .success(ControlRequest(id: members["id"], method: method, params: members["params"]?.objectValue ?? [:],
                                       flow: flow(members["flow"]), source: source(members["source"])))
    }

    /// `value` as the caller's named source (``ControlRequestScope/Source/init(wire:)``), else nil (ignored, never refused).
    static func source(_ value: JSONValue?) -> ControlRequestScope.Source? {
        value?.stringValue.flatMap(ControlRequestScope.Source.init(wire:))
    }

    /// The largest flow id: 2^53 - 1, the largest integer every JSON number holds exactly.
    static let maxFlow: UInt64 = (1 << 53) - 1

    /// `value` as a flow id: a whole number from 1 to ``maxFlow``, else nil (ignored, never refused).
    static func flow(_ value: JSONValue?) -> UInt64? {
        guard case .number(let number) = value, number >= 1, number <= Double(maxFlow) else { return nil }
        return UInt64(exactly: number)
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
        // Saturates for durations past Int.max milliseconds instead of trapping.
        return Int(clamping: seconds).saturatingMultiplication(1_000)
            .saturatingAddition(Int(clamping: attoseconds / 1_000_000_000_000_000))
    }

    var fractionalMilliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    var formattedMilliseconds: String { "\(wholeMilliseconds) ms" }
}
