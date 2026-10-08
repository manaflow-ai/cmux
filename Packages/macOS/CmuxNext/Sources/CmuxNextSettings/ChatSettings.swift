public import Foundation

/// Effective chat discovery preferences, with user and administrator roots kept distinct.
public nonisolated struct ChatSettings: Sendable, Equatable {
    public let enabled: Bool
    public let discovery: Bool
    public let roots: [String]
    public let managedRoots: [String]

    public static let rootsPath = ["agents", "chats", "roots"]
    public static let booleanKeys = ["agents.chats.enabled", "agents.chats.discovery"]
    public static let keys = Set(booleanKeys + ["agents.chats.roots"])

    /// Builds the daemon payload from the effective switches and each roots layer. Refused roots
    /// remain visible in Settings but never reach the daemon.
    public init(effective: JSONValue, file: JSONValue, managedRoots: [String], validator: ChatRootValidator = .init()) {
        enabled = effective.value(at: ["agents", "chats", "enabled"])?.boolValue ?? true
        discovery = effective.value(at: ["agents", "chats", "discovery"])?.boolValue ?? true
        roots = Self.strings(file.value(at: Self.rootsPath)).filter { validator.refusal($0) == nil }
        self.managedRoots = Self.unique(managedRoots).filter { validator.refusal($0) == nil }
    }

    /// `_acpmux/chat_settings` params. The daemon persists this device-local projection.
    public var params: JSONValue {
        ["enabled": .bool(enabled), "discovery": .bool(discovery),
         "roots": .array(roots.map(JSONValue.string)), "managedRoots": .array(managedRoots.map(JSONValue.string))]
    }

    /// Initialize followed by one request, each terminated by a newline.
    public var request: Data {
        let initialize: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": 1, "clientInfo": ["name": "cmux-next-chat-settings", "version": "1"], "clientCapabilities": .object([:])]]
        let update: JSONValue = ["jsonrpc": "2.0", "id": 2, "method": "_acpmux/chat_settings", "params": params]
        return Data((initialize.compactText + "\n" + update.compactText + "\n").utf8)
    }

    static func strings(_ value: JSONValue?) -> [String] { unique(value?.arrayValue?.compactMap(\.stringValue) ?? []) }
    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
