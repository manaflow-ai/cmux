import Foundation

/// Wire frame sent from hook subcommands and the OpenCode plugin to the
/// cmux socket, then materialized into a `WorkstreamItem` by the store.
///
/// Field names mirror Vibe Island's hook payload format exactly so existing
/// agent payloads pass through untouched: `session_id`, `hook_event_name`,
/// `cwd`, `tool_name`, `tool_input`, `_source`, `_ppid`,
/// `_opencode_request_id`. `context` is cmux-specific and optional.
public struct WorkstreamEvent: Codable, Sendable, Equatable {
    public let sessionId: String
    public let hookEventName: HookEventName
    public let source: String
    public let cwd: String?
    public let toolName: String?
    public let toolInputJSON: String?
    public let context: WorkstreamContext?
    public let requestId: String?
    public let ppid: Int?
    public let receivedAt: Date
    public let extraFieldsJSON: String?

    public init(
        sessionId: String,
        hookEventName: HookEventName,
        source: String,
        cwd: String? = nil,
        toolName: String? = nil,
        toolInputJSON: String? = nil,
        context: WorkstreamContext? = nil,
        requestId: String? = nil,
        ppid: Int? = nil,
        receivedAt: Date = Date(),
        extraFieldsJSON: String? = nil
    ) {
        self.sessionId = sessionId
        self.hookEventName = hookEventName
        self.source = source
        self.cwd = cwd
        self.toolName = toolName
        self.toolInputJSON = toolInputJSON
        self.context = context
        self.requestId = requestId
        self.ppid = ppid
        self.receivedAt = receivedAt
        self.extraFieldsJSON = extraFieldsJSON
    }

    /// Hook event discriminator. Values match the strings Vibe Island and
    /// cmux hook wrappers already emit on stdin so no translation layer is
    /// needed.
    public enum HookEventName: String, Codable, Sendable, Equatable {
        case sessionStart = "SessionStart"
        case sessionEnd = "SessionEnd"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case permissionRequest = "PermissionRequest"
        case askUserQuestion = "AskUserQuestion"
        case exitPlanMode = "ExitPlanMode"
        case todoWrite = "TodoWrite"
        case stop = "Stop"
        case subagentStop = "SubagentStop"
        case notification = "Notification"
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sessionId = "session_id"
        case hookEventName = "hook_event_name"
        case source = "_source"
        case cwd
        case toolName = "tool_name"
        case toolInputJSON = "tool_input"
        case context
        case requestId = "_opencode_request_id"
        case ppid = "_ppid"
        case receivedAt = "_received_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try c.decode(String.self, forKey: .sessionId)
        self.hookEventName = try c.decode(HookEventName.self, forKey: .hookEventName)
        self.source = try c.decode(String.self, forKey: .source)
        self.cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        self.toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        self.context = try c.decodeIfPresent(WorkstreamContext.self, forKey: .context)
        self.requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        self.ppid = try c.decodeIfPresent(Int.self, forKey: .ppid)
        self.receivedAt = try c.decodeIfPresent(Date.self, forKey: .receivedAt) ?? Date()
        let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))
        let dynamic = try decoder.container(keyedBy: JSONDynamicKey.self)
        var extra: [String: AnyJSON] = [:]
        for key in dynamic.allKeys where !knownKeys.contains(key.stringValue) {
            extra[key.stringValue] = try dynamic.decode(AnyJSON.self, forKey: key)
        }
        self.extraFieldsJSON = extra.isEmpty ? nil : AnyJSON.object(extra).asJSONString
        // tool_input can be any JSON shape (object, array, scalar, string).
        // We normalize to a string: incoming objects/arrays are re-serialized
        // via JSONSerialization; incoming strings are stored verbatim so
        // consumers can parse whatever agent-specific structure they want.
        if let raw = try? c.decode(AnyJSON.self, forKey: .toolInputJSON) {
            self.toolInputJSON = raw.asJSONString
        } else {
            self.toolInputJSON = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(hookEventName, forKey: .hookEventName)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(toolName, forKey: .toolName)
        try c.encodeIfPresent(context, forKey: .context)
        try c.encodeIfPresent(requestId, forKey: .requestId)
        try c.encodeIfPresent(ppid, forKey: .ppid)
        try c.encode(receivedAt, forKey: .receivedAt)
        if let extraFieldsJSON,
           case .object(let extra) = AnyJSON(jsonString: extraFieldsJSON) {
            let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))
            var dynamic = encoder.container(keyedBy: JSONDynamicKey.self)
            for (key, value) in extra where !knownKeys.contains(key) {
                guard let codingKey = JSONDynamicKey(stringValue: key) else { continue }
                try dynamic.encode(value, forKey: codingKey)
            }
        }
        if let toolInputJSON {
            let raw = AnyJSON(jsonString: toolInputJSON) ?? .string(toolInputJSON)
            try c.encode(raw, forKey: .toolInputJSON)
        }
    }
}

private struct JSONDynamicKey: CodingKey {
    let stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { self.stringValue = String(intValue) }
}

/// Recursive AST of opaque JSON values. Used to pass arbitrary
/// `tool_input` shapes through `Codable` without rebuilding the raw
/// bytes ourselves.
private indirect enum AnyJSON: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])

    /// Stable textual form: valid JSON, object keys sorted so persisted
    /// output is deterministic.
    var asJSONString: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return Self.escapeString(s)
        case .array(let arr):
            return "[" + arr.map { $0.asJSONString }.joined(separator: ",") + "]"
        case .object(let dict):
            let pieces = dict
                .map { (k, v) in "\(Self.escapeString(k)):\(v.asJSONString)" }
                .sorted()
            return "{" + pieces.joined(separator: ",") + "}"
        }
    }

    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]
              )
        else { return nil }
        self = Self.fromAny(value)
    }

    private static func fromAny(_ value: Any) -> AnyJSON {
        if value is NSNull { return .null }
        if let n = value as? NSNumber {
            // NSNumber distinguishes Bool via objCType == "c" (char).
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            if CFNumberIsFloatType(n) {
                return .double(n.doubleValue)
            }
            return .int(Int(n.int64Value))
        }
        if let s = value as? String { return .string(s) }
        if let arr = value as? [Any] { return .array(arr.map(fromAny)) }
        if let dict = value as? [String: Any] {
            var out: [String: AnyJSON] = [:]
            for (k, v) in dict { out[k] = fromAny(v) }
            return .object(out)
        }
        return .null
    }

    private static func escapeString(_ s: String) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: s, options: [.fragmentsAllowed]
        )
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: JSONDynamicKey.self) {
            var out: [String: AnyJSON] = [:]
            for key in keyed.allKeys {
                out[key.stringValue] = try keyed.decode(AnyJSON.self, forKey: key)
            }
            self = .object(out)
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var out: [AnyJSON] = []
            while !unkeyed.isAtEnd {
                out.append(try unkeyed.decode(AnyJSON.self))
            }
            self = .array(out)
            return
        }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
            return
        }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "Unsupported JSON value"
        )
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        case .bool(let b):
            var c = encoder.singleValueContainer()
            try c.encode(b)
        case .int(let i):
            var c = encoder.singleValueContainer()
            try c.encode(i)
        case .double(let d):
            var c = encoder.singleValueContainer()
            try c.encode(d)
        case .string(let s):
            var c = encoder.singleValueContainer()
            try c.encode(s)
        case .array(let arr):
            var c = encoder.unkeyedContainer()
            for v in arr { try c.encode(v) }
        case .object(let dict):
            var c = encoder.container(keyedBy: JSONDynamicKey.self)
            for (k, v) in dict {
                guard let key = JSONDynamicKey(stringValue: k) else { continue }
                try c.encode(v, forKey: key)
            }
        }
    }
}
