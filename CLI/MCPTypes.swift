// MCPTypes.swift
// JSON-RPC 2.0 and MCP protocol types

import Foundation

// MARK: - JSON-RPC 2.0 Types

/// JSON-RPC 2.0 Request
public struct JSONRPCRequest: Codable {
    public let jsonrpc: String
    public let id: JSONRPCId
    public let method: String
    public let params: [String: AnyCodable]?

    public init(id: JSONRPCId, method: String, params: [String: AnyCodable]? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

/// JSON-RPC 2.0 Response (success)
public struct JSONRPCResponse: Codable {
    public let jsonrpc: String
    public let id: JSONRPCId
    public let result: AnyCodable?

    public init(id: JSONRPCId, result: Any?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result.map { AnyCodable($0) }
    }
}

/// JSON-RPC 2.0 Response (error)
public struct JSONRPCError: Codable {
    public let code: Int
    public let message: String
    public let data: AnyCodable?

    public init(code: Int, message: String, data: Any? = nil) {
        self.code = code
        self.message = message
        self.data = data.map { AnyCodable($0) }
    }
}

/// JSON-RPC 2.0 Error Response
public struct JSONRPCErrorResponse: Codable {
    public let jsonrpc: String
    public let id: JSONRPCId
    public let error: JSONRPCError

    public init(id: JSONRPCId, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.error = error
    }
}

/// JSON-RPC 2.0 Notification (no id)
public struct JSONRPCNotification: Codable {
    public let jsonrpc: String
    public let method: String
    public let params: [String: AnyCodable]?

    public init(method: String, params: [String: AnyCodable]? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

/// JSON-RPC ID (can be string or number)
public enum JSONRPCId: Codable, Equatable, Hashable {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .number(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSON-RPC id")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }
}

/// JSON-RPC Error Codes
public enum JSONRPCErrorCode: Int {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
    case serverError = -32000
}

// MARK: - AnyCodable Helper

/// Type-erased Codable wrapper for dynamic JSON values
public struct AnyCodable: Codable, Equatable, Hashable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            self.value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            let context = EncodingError.Context(codingPath: container.codingPath, debugDescription: "Unsupported type")
            throw EncodingError.invalidValue(value, context)
        }
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case (let l as NSNull, let r as NSNull):
            return true
        case (let l as Bool, let r as Bool):
            return l == r
        case (let l as Int, let r as Int):
            return l == r
        case (let l as Double, let r as Double):
            return l == r
        case (let l as String, let r as String):
            return l == r
        case (let l as [Any], let r as [Any]):
            return l.count == r.count && zip(l, r).allSatisfy { AnyCodable($0) == AnyCodable($1) }
        case (let l as [String: Any], let r as [String: Any]):
            return l.count == r.count && l.keys.allSatisfy { key in
                guard let lv = l[key], let rv = r[key] else { return false }
                return AnyCodable(lv) == AnyCodable(rv)
            }
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch value {
        case is NSNull:
            hasher.combine(0)
        case let bool as Bool:
            hasher.combine(bool)
        case let int as Int:
            hasher.combine(int)
        case let double as Double:
            hasher.combine(double)
        case let string as String:
            hasher.combine(string)
        default:
            // For complex types, use description
            hasher.combine(String(describing: value))
        }
    }
}

// MARK: - MCP Protocol Types

/// MCP Initialize parameters
public struct MCPInitializeParams: Codable {
    public let protocolVersion: String
    public let capabilities: MCPCapabilities
    public let clientInfo: MCPClientInfo

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocolVersion"
        case capabilities
        case clientInfo = "clientInfo"
    }
}

/// MCP Client Info
public struct MCPClientInfo: Codable {
    public let name: String
    public let version: String
}

/// MCP Server Info
public struct MCPServerInfo: Codable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// MCP Capabilities
public struct MCPCapabilities: Codable {
    public let tools: MCPToolsCapability?
    public let resources: MCPResourcesCapability?
    public let prompts: MCPPromptsCapability?

    public init(tools: MCPToolsCapability? = nil, resources: MCPResourcesCapability? = nil, prompts: MCPPromptsCapability? = nil) {
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
    }
}

/// MCP Tools Capability
public struct MCPToolsCapability: Codable {
    public let listChanged: Bool?

    public init(listChanged: Bool? = nil) {
        self.listChanged = listChanged
    }
}

/// MCP Resources Capability
public struct MCPResourcesCapability: Codable {
    public let subscribe: Bool?
    public let listChanged: Bool?
}

/// MCP Prompts Capability
public struct MCPPromptsCapability: Codable {
    public let listChanged: Bool?
}

/// MCP Initialize Result
public struct MCPInitializeResult: Codable {
    public let protocolVersion: String
    public let capabilities: MCPCapabilities
    public let serverInfo: MCPServerInfo

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocolVersion"
        case capabilities
        case serverInfo = "serverInfo"
    }

    public init(protocolVersion: String, capabilities: MCPCapabilities, serverInfo: MCPServerInfo) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
    }
}

// MARK: - MCP Tool Types

/// MCP Tool definition
public struct MCPToolDefinition: Codable {
    public let name: String
    public let description: String
    public let inputSchema: MCPToolInputSchema

    public init(name: String, description: String, inputSchema: MCPToolInputSchema) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// MCP Tool Input Schema
public struct MCPToolInputSchema: Codable {
    public let type: String
    public let properties: [String: MCPToolProperty]?
    public let required: [String]?

    public init(type: String = "object", properties: [String: MCPToolProperty]? = nil, required: [String]? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

/// MCP Tool Property
public struct MCPToolProperty: Codable {
    public let type: String
    public let description: String?
    public let items: MCPToolPropertyItems?

    public init(type: String, description: String? = nil, items: MCPToolPropertyItems? = nil) {
        self.type = type
        self.description = description
        self.items = items
    }
}

/// MCP Tool Property Items (for arrays)
public struct MCPToolPropertyItems: Codable {
    public let type: String

    public init(type: String) {
        self.type = type
    }
}

/// MCP Tools List Result
public struct MCPToolsListResult: Codable {
    public let tools: [MCPToolDefinition]

    public init(tools: [MCPToolDefinition]) {
        self.tools = tools
    }
}

/// MCP Tool Call Parameters
public struct MCPToolCallParams: Codable {
    public let name: String
    public let arguments: [String: AnyCodable]?

    public init(name: String, arguments: [String: AnyCodable]? = nil) {
        self.name = name
        self.arguments = arguments
    }
}

/// MCP Tool Call Result
public struct MCPToolCallResult: Codable {
    public let content: [MCPContentBlock]

    public init(content: [MCPContentBlock]) {
        self.content = content
    }
}

/// MCP Content Block (for tool results)
public struct MCPContentBlock: Codable {
    public let type: String
    public let text: String?

    public init(type: String = "text", text: String? = nil) {
        self.type = type
        self.text = text
    }

    public static func text(_ text: String) -> MCPContentBlock {
        MCPContentBlock(type: "text", text: text)
    }
}
