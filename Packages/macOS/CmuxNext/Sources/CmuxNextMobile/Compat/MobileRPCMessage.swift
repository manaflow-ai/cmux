public import CmuxNextDaemon
public import Foundation

/// One shipped-iOS mobile RPC request: `{"id","method","params","auth"?}`.
/// `auth` is ignored on irx: admission already proved the same account.
public struct MobileRPCRequest: Sendable {
    public var id: JSONValue
    public var method: String
    public var params: [String: JSONValue]

    public init(id: JSONValue, method: String, params: [String: JSONValue] = [:]) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// Decodes one frame payload; nil when it is not a request object.
    public init?(frame: Data) {
        guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: frame),
              let method = object["method"]?.stringValue else { return nil }
        id = object["id"] ?? .null
        self.method = method
        if case .object(let params)? = object["params"] { self.params = params } else { params = [:] }
    }

    public func string(_ key: String) -> String? {
        guard let value = params[key]?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    public func int(_ key: String) -> Int? {
        switch params[key] {
        case .number(let value)?: Int(exactly: value.rounded())
        case .string(let value)?: Int(value)
        default: nil
        }
    }
}

/// A typed RPC failure with the wire code the phone switches on.
public struct MobileRPCError: Error, Sendable, Equatable {
    public var code: String
    public var message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public static func methodNotFound(_ method: String) -> Self {
        Self("method_not_found", "\(method) is not supported by this Mac")
    }

    public static func invalidParams(_ message: String) -> Self { Self("invalid_params", message) }
    public static func notFound(_ message: String) -> Self { Self("not_found", message) }
}

/// Wire encoding for responses and events (JSON objects inside
/// `MobileSyncFrameCodec` frames).
public struct MobileRPCWire {
    public init() {}
    public static func success(id: JSONValue, result: JSONValue) -> Data {
        encode(.object(["id": id, "ok": .bool(true), "result": result]))
    }

    public static func failure(id: JSONValue, error: MobileRPCError) -> Data {
        encode(.object(["id": id, "ok": .bool(false),
                        "error": .object(["code": .string(error.code), "message": .string(error.message)])]))
    }

    public static func event(topic: String, payload: JSONValue) -> Data {
        encode(.object(["kind": .string("event"), "topic": .string(topic), "payload": payload]))
    }

    static func encode(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }
}

extension JSONValue {
    static func int(_ value: Int) -> JSONValue { .number(Double(value)) }
    static func uint(_ value: UInt64) -> JSONValue { .number(Double(value)) }
    static func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }
}
