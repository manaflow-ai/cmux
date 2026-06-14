internal import Foundation

/// Encodes v2 control-protocol responses as single-line JSON strings (was
/// `v2Encode`/`v2Ok`/`v2Error`/`v2Result` on `TerminalController`).
///
/// Output is byte-compatible with the legacy encoder: `JSONSerialization`
/// does the serialization, a missing `id` encodes as JSON `null`, `error.data`
/// is omitted when `nil`, unencodable payloads collapse to
/// `encodeFailureResponse`, and any newline is escaped so the line-oriented
/// protocol never sees an embedded line break.
public struct ControlResponseEncoder: Sendable {
    /// The fixed fallback emitted when a payload cannot be encoded.
    public static let encodeFailureResponse =
        "{\"ok\":false,\"error\":{\"code\":\"encode_error\",\"message\":\"Failed to encode JSON\"}}"

    /// Creates an encoder.
    public init() {}

    /// Encodes a success response: `{"id":…,"ok":true,"result":…}`.
    ///
    /// - Parameters:
    ///   - id: The request id to echo; `nil` encodes as `null`.
    ///   - result: The result payload.
    /// - Returns: The single-line response.
    public func ok(id: JSONValue?, result: JSONValue) -> String {
        encode(.object([
            "id": id ?? .null,
            "ok": .bool(true),
            "result": result,
        ]))
    }

    /// Encodes a failure response: `{"id":…,"ok":false,"error":…}`.
    ///
    /// - Parameters:
    ///   - id: The request id to echo; `nil` encodes as `null`.
    ///   - code: The machine-readable error code.
    ///   - message: The human-readable error message.
    ///   - data: Optional structured detail; omitted when `nil`.
    /// - Returns: The single-line response.
    public func error(id: JSONValue?, code: String, message: String, data: JSONValue? = nil) -> String {
        var errorObject: [String: JSONValue] = [
            "code": .string(code),
            "message": .string(message),
        ]
        if let data {
            errorObject["data"] = data
        }
        return encode(.object([
            "id": id ?? .null,
            "ok": .bool(false),
            "error": .object(errorObject),
        ]))
    }

    /// Encodes a call result onto the wire.
    ///
    /// - Parameters:
    ///   - id: The request id to echo.
    ///   - result: The call outcome.
    /// - Returns: The single-line response.
    public func response(id: JSONValue?, _ result: ControlCallResult) -> String {
        switch result {
        case .ok(let payload):
            return ok(id: id, result: payload)
        case .err(let code, let message, let data):
            return error(id: id, code: code, message: message, data: data)
        }
    }

    /// Encodes the dispatcher error response for a request-envelope parse
    /// failure, matching the legacy strings exactly. The UTF-8/JSON/object
    /// defects predate id extraction, so those responses carry no `id` key;
    /// only `missingMethod` echoes the id.
    ///
    /// - Parameter parseError: The classified parse failure.
    /// - Returns: The single-line response.
    public func response(for parseError: ControlRequestParseError) -> String {
        switch parseError {
        case .invalidUTF8:
            return encode(.object([
                "ok": .bool(false),
                "error": .object(["code": .string("invalid_utf8"), "message": .string("Invalid UTF-8")]),
            ]))
        case .invalidJSON:
            return encode(.object([
                "ok": .bool(false),
                "error": .object(["code": .string("parse_error"), "message": .string("Invalid JSON")]),
            ]))
        case .notAnObject:
            return encode(.object([
                "ok": .bool(false),
                "error": .object(["code": .string("invalid_request"), "message": .string("Expected JSON object")]),
            ]))
        case .missingMethod(let id):
            return error(id: id, code: "invalid_request", message: "Missing method")
        }
    }

    /// Serializes a value as one line of JSON.
    ///
    /// - Parameter value: The value to serialize. The top level must be an
    ///   object or array (`JSONSerialization` rules); anything else collapses
    ///   to `encodeFailureResponse`.
    /// - Returns: The single-line JSON string.
    public func encode(_ value: JSONValue) -> String {
        let object = value.foundationObject
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              var string = String(data: data, encoding: .utf8) else {
            return Self.encodeFailureResponse
        }
        // Ensure single-line responses for the line-oriented socket protocol.
        string = string.replacingOccurrences(of: "\n", with: "\\n")
        return string
    }
}
