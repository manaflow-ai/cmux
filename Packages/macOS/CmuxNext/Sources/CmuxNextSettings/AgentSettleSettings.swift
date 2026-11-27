// The paths, defaults and range are generated from schemas/settings/source/agent-settle.json
// (Schema/SettingsSchema+AgentSettle.generated.swift); this file only holds them.

/// `agents.autoSettle.*` in cmux.json (Settings > General > Settle Chats). The acpmux daemon reads
/// the same file and settles chats itself (cmux-tui/crates/acpmux/src/hub/auto_settle.rs); the app
/// only shows and validates the keys, so the palette, `cmux settings` and MCP reach them.
public nonisolated struct AgentSettleSettings: Sendable, Equatable {
    public var onMerge = AgentSettleSettings.autoSettleOnMergeDefault
    public var onClose = AgentSettleSettings.autoSettleOnCloseDefault
    public var idleDays = AgentSettleSettings.autoSettleIdleDaysDefault

    public init() {}
}
