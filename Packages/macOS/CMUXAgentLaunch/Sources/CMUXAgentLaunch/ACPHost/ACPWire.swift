import Foundation

/// How a JSON-RPC 2.0 identifier arrived on the wire.
///
/// JSON-RPC allows a number or a string, and a response has to echo the exact
/// value it was sent. Normalizing both to `String` would answer `7` with `"7"`,
/// which a strict client reads as a reply to a request it never made.
public enum ACPRequestIdentifier: Sendable, Equatable {
    case number(Int)
    case string(String)

    /// The value to put back in a response, in the shape it arrived.
    public var jsonValue: Any {
        switch self {
        case .number(let value): return value
        case .string(let value): return value
        }
    }

    /// Reads an identifier out of a decoded JSON-RPC envelope.
    ///
    /// `null` is deliberately not an identifier: JSON-RPC 2.0 reserves it for
    /// the error reply to a request whose id could not be read, so a request
    /// carrying `"id": null` is malformed rather than a notification.
    static func from(_ raw: Any?) -> ACPRequestIdentifier? {
        switch raw {
        case let value as Int: return .number(value)
        case let value as String: return .string(value)
        case let value as NSNumber where value.doubleValue == value.doubleValue.rounded():
            return .number(value.intValue)
        default: return nil
        }
    }
}

/// One decoded JSON-RPC 2.0 message from an ACP client.
///
/// ACP frames are newline-delimited JSON objects on stdio, so decoding is
/// per line and a bad line is reported rather than thrown: a stream that
/// carries one unparseable frame has to keep serving the frames after it.
public struct ACPIncomingMessage {
    /// Why a line could not become a message.
    ///
    /// Separate cases because they get different JSON-RPC error codes and
    /// because only some of them can be answered at all (an answer needs an
    /// id, and a line that is not an object has none).
    public enum Problem: Error, Sendable, Equatable {
        /// Not parseable as JSON at all.
        case notJSON
        /// Valid JSON, but not an object (JSON-RPC requires an object).
        case notAnObject
        /// Missing or wrong `jsonrpc` member.
        case wrongVersion(String?)
        /// No `method`, or a `method` that is not a string.
        case missingMethod(ACPRequestIdentifier?)
        /// `params` present but not an object. ACP only ever sends objects,
        /// so an array here is a client bug worth naming instead of ignoring.
        case paramsNotAnObject(ACPRequestIdentifier?)

        /// The id to answer with, when the line carried a usable one.
        public var identifier: ACPRequestIdentifier? {
            switch self {
            case .notJSON, .notAnObject, .wrongVersion: return nil
            case .missingMethod(let id), .paramsNotAnObject(let id): return id
            }
        }
    }

    /// Absent for a notification, which must never be answered.
    public let id: ACPRequestIdentifier?
    public let method: String
    public let params: [String: Any]

    /// True when the sender expects no response.
    public var isNotification: Bool { id == nil }

    public init(id: ACPRequestIdentifier?, method: String, params: [String: Any]) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// Decodes one line of the stdio stream.
    ///
    /// A blank line is `.notJSON` rather than a silent success, so the caller
    /// decides whether to skip it; the reader skips blanks before calling here,
    /// which keeps "the client sent whitespace" out of the error stream.
    public static func decode(line: String) -> Result<ACPIncomingMessage, Problem> {
        guard let data = line.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return .failure(.notJSON) }
        guard let object = parsed as? [String: Any] else { return .failure(.notAnObject) }
        let id = ACPRequestIdentifier.from(object["id"])
        let version = object["jsonrpc"] as? String
        guard version == "2.0" else { return .failure(.wrongVersion(version)) }
        guard let method = object["method"] as? String, !method.isEmpty else {
            return .failure(.missingMethod(id))
        }
        let params: [String: Any]
        switch object["params"] {
        case nil, is NSNull:
            params = [:]
        case let object as [String: Any]:
            params = object
        default:
            return .failure(.paramsNotAnObject(id))
        }
        return .success(ACPIncomingMessage(id: id, method: method, params: params))
    }
}

/// JSON-RPC 2.0 error codes, plus the one range ACP reserves for itself.
public enum ACPErrorCode {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    /// ACP's own space for agent-defined failures, which starts at -32000.
    public static let sessionNotFound = -32000
    public static let hostUnavailable = -32001
}

/// Builds the envelopes this host writes back to the client.
public enum ACPOutgoingMessage {
    /// A successful response. `result` is always an object, never bare `null`,
    /// so a client can add fields to its handling later without special-casing.
    public static func result(id: ACPRequestIdentifier, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id.jsonValue, "result": result]
    }

    /// An error response. A nil id becomes JSON `null`, which is what JSON-RPC
    /// requires when the request's own id could not be read.
    public static func failure(
        id: ACPRequestIdentifier?,
        code: Int,
        message: String,
        data: [String: Any]? = nil
    ) -> [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        return ["jsonrpc": "2.0", "id": id?.jsonValue ?? NSNull(), "error": error]
    }

    public static func notification(method: String, params: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "method": method, "params": params]
    }

    /// Serializes one envelope as a single line.
    ///
    /// No pretty printing and sorted keys: the framing is one JSON object per
    /// line, so an embedded newline would split one message into two, and
    /// stable key order makes the stream diffable in a test or a capture.
    /// Returns nil for a payload JSONSerialization refuses, which the caller
    /// has to report rather than send a truncated frame.
    public static func line(_ envelope: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(
                  withJSONObject: envelope,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }
}
