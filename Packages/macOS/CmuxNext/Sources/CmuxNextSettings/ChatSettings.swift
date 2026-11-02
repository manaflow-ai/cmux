public import Foundation

/// Effective chat discovery preferences, with user and administrator roots kept distinct, and the
/// effective `agents.defaultPermissionMode` and `sessions.allowFullAccess`: the daemon reads only the
/// settings file, so a value MDM or the team policy forces reaches it only here
/// (`cmux-tui/crates/acpmux/src/hub/start_mode_state.rs`).
public nonisolated struct ChatSettings: Sendable, Equatable {
    public let enabled: Bool
    public let discovery: Bool
    public let roots: [String]
    public let managedRoots: [String]
    /// The effective permission mode for new chats, or nil when no layer sets one (`""` when a
    /// forced value is not a string).
    public let permissionMode: String?
    /// Whether MDM or the team policy forces `permissionMode`; then it beats the file and every pick.
    public let permissionModeManaged: Bool
    /// The `sessions.allowFullAccess` MDM or the team policy forces (`false` for a forced value that is
    /// not `true`), nil when nothing forces it. acpmux takes a forced off as an upper bound the user
    /// cannot override; a forced on adds nothing; nil changes nothing (claude-sr2, 2026-10-25).
    public let fullAccessManaged: Bool?

    // Paths and defaults: schemas/settings/source/chats.json (SettingsSchema+Chats.generated.swift).
    public static let booleanKeys = [enabledPath, discoveryPath].map { $0.joined(separator: ".") }
    public static let keys = Set(booleanKeys + [rootsPath.joined(separator: ".")])

    /// Builds the daemon payload from the effective switches and each roots layer. Refused roots
    /// remain visible in Settings but never reach the daemon.
    public init(effective: JSONValue, file: JSONValue, managedRoots: [String], managedKeys: [String: ManagedSource] = [:],
                validator: ChatRootValidator = .init()) {
        enabled = effective.value(at: Self.enabledPath)?.boolValue ?? Self.enabledDefault
        discovery = effective.value(at: Self.discoveryPath)?.boolValue ?? Self.discoveryDefault
        roots = Self.strings(file.value(at: Self.rootsPath)).filter { validator.refusal($0) == nil }
        self.managedRoots = Self.unique(managedRoots).filter { validator.refusal($0) == nil }
        let modePath = AgentDefaultsSettingsSchema.permissionModePath
        permissionModeManaged = managedKeys[modePath.joined(separator: ".")] != nil
        // A forced value that is not a string goes out as one the daemon does not know (`""`), which
        // it treats as the harness's own mode; dropping it would let the file or a pick choose.
        let mode = effective.value(at: modePath)?.stringValue
        permissionMode = permissionModeManaged ? (mode ?? "") : mode
        let fullAccessPath = SessionSettings.allowFullAccessPath
        fullAccessManaged = managedKeys[fullAccessPath.joined(separator: ".")] == nil
            ? nil : effective.value(at: fullAccessPath)?.boolValue == true
    }

    /// `_acpmux/chat_settings` params. The daemon persists this device-local projection.
    public var params: JSONValue {
        ["enabled": .bool(enabled), "discovery": .bool(discovery),
         "roots": .array(roots.map(JSONValue.string)), "managedRoots": .array(managedRoots.map(JSONValue.string)),
         "permissionMode": permissionMode.map(JSONValue.string) ?? .null, "permissionModeManaged": .bool(permissionModeManaged),
         "allowFullAccess": fullAccessManaged.map(JSONValue.bool) ?? .null, "allowFullAccessManaged": .bool(fullAccessManaged != nil)]
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
