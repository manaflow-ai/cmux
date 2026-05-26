import Foundation

struct CodexAppServerMethodSchema: Equatable {
    let method: String
    let messageSchemaName: String
    let paramsSchemaName: String?
}

enum CodexAppServerJSONValue: Codable, Equatable {
    case object([String: CodexAppServerJSONValue])
    case array([CodexAppServerJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([CodexAppServerJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: CodexAppServerJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    static func fromAny(_ value: Any) -> CodexAppServerJSONValue {
        if value is NSNull {
            return .null
        }
        if let value = value as? String {
            return .string(value)
        }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        }
        if let value = value as? Bool {
            return .bool(value)
        }
        if let value = value as? Int {
            return .number(Double(value))
        }
        if let value = value as? Double {
            return .number(value)
        }
        if let value = value as? [Any] {
            return .array(value.map(CodexAppServerJSONValue.fromAny))
        }
        if let value = value as? [String: Any] {
            return .object(value.mapValues(CodexAppServerJSONValue.fromAny))
        }
        return .string(String(describing: value))
    }

    var anyValue: Any {
        switch self {
        case .object(let value):
            return value.mapValues(\.anyValue)
        case .array(let value):
            return value.map(\.anyValue)
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .null:
            return NSNull()
        }
    }

    var objectValue: [String: Any]? {
        guard case .object(let value) = self else { return nil }
        return value.mapValues(\.anyValue)
    }
}

struct CodexAppServerServerNotification: Equatable {
    let method: CodexAppServerServerNotificationMethod?
    let rawMethod: String
    let params: CodexAppServerJSONValue?

    var schema: CodexAppServerMethodSchema? {
        CodexAppServerProtocolSchemas.serverNotificationSchema(for: rawMethod)
    }

    var paramsObject: [String: Any]? {
        params?.objectValue
    }

    init(method: String, params: Any?) {
        self.method = CodexAppServerServerNotificationMethod(rawValue: method)
        self.rawMethod = method
        self.params = params.map(CodexAppServerJSONValue.fromAny)
    }
}

struct CodexAppServerServerRequest: Equatable {
    let id: CodexAppServerRequestID
    let method: CodexAppServerServerRequestMethod?
    let rawMethod: String
    let params: CodexAppServerJSONValue?

    var schema: CodexAppServerMethodSchema? {
        CodexAppServerProtocolSchemas.serverRequestSchema(for: rawMethod)
    }

    var paramsObject: [String: Any]? {
        params?.objectValue
    }

    init(id: CodexAppServerRequestID, method: String, params: Any?) {
        self.id = id
        self.method = CodexAppServerServerRequestMethod(rawValue: method)
        self.rawMethod = method
        self.params = params.map(CodexAppServerJSONValue.fromAny)
    }

    init(id: Int, method: String, params: Any?) {
        self.init(id: .int(id), method: method, params: params)
    }
}

struct CodexAppServerClientRequestEnvelope: Equatable {
    let id: Int
    let method: CodexAppServerClientRequestMethod?
    let rawMethod: String
    let params: CodexAppServerJSONValue?

    var schema: CodexAppServerMethodSchema? {
        CodexAppServerProtocolSchemas.clientRequestSchema(for: rawMethod)
    }

    init(id: Int, method: String, params: Any?) {
        self.id = id
        self.method = CodexAppServerClientRequestMethod(rawValue: method)
        self.rawMethod = method
        self.params = params.map(CodexAppServerJSONValue.fromAny)
    }
}

struct CodexAppServerClientNotificationEnvelope: Equatable {
    let method: CodexAppServerClientNotificationMethod?
    let rawMethod: String
    let params: CodexAppServerJSONValue?

    var schema: CodexAppServerMethodSchema? {
        CodexAppServerProtocolSchemas.clientNotificationSchema(for: rawMethod)
    }

    init(method: String, params: Any?) {
        self.method = CodexAppServerClientNotificationMethod(rawValue: method)
        self.rawMethod = method
        self.params = params.map(CodexAppServerJSONValue.fromAny)
    }
}

enum CodexAppServerProtocolSchemas {
    static let sourceRemote = CodexAppServerGeneratedSchemas.sourceRemote
    static let sourceBranch = CodexAppServerGeneratedSchemas.sourceBranch
    static let sourceRevision = CodexAppServerGeneratedSchemas.sourceRevision
    static let schemaDigest = CodexAppServerGeneratedSchemas.schemaDigest

    private static let serverNotificationByMethod = Dictionary(
        uniqueKeysWithValues: CodexAppServerGeneratedSchemas.serverNotificationSchemas.map { ($0.method, $0) }
    )
    private static let serverRequestByMethod = Dictionary(
        uniqueKeysWithValues: CodexAppServerGeneratedSchemas.serverRequestSchemas.map { ($0.method, $0) }
    )
    private static let clientRequestByMethod = Dictionary(
        uniqueKeysWithValues: CodexAppServerGeneratedSchemas.clientRequestSchemas.map { ($0.method, $0) }
    )
    private static let clientNotificationByMethod = Dictionary(
        uniqueKeysWithValues: CodexAppServerGeneratedSchemas.clientNotificationSchemas.map { ($0.method, $0) }
    )

    static func serverNotificationSchema(for method: String) -> CodexAppServerMethodSchema? {
        serverNotificationByMethod[method]
    }

    static func serverRequestSchema(for method: String) -> CodexAppServerMethodSchema? {
        serverRequestByMethod[method]
    }

    static func clientRequestSchema(for method: String) -> CodexAppServerMethodSchema? {
        clientRequestByMethod[method]
    }

    static func clientNotificationSchema(for method: String) -> CodexAppServerMethodSchema? {
        clientNotificationByMethod[method]
    }

    static func rootSchemaJSON(named name: String) -> String? {
        guard let encoded = CodexAppServerGeneratedSchemas.rootSchemaBase64ByName[name] else {
            return nil
        }
        let compacted = String(encoded.filter { !$0.isWhitespace })
        guard let data = Data(base64Encoded: compacted) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
