import Foundation

/// The operations each settings descriptor exposes on the non-UI surfaces.
///
/// This is derived from the one native descriptor registry and exported with
/// `schemas/settings/settings-schema.json`; the daemon, CLI and MCP clients
/// consume that export instead of keeping their own key lists.
public nonisolated struct SettingSurfaceAvailability: Sendable, Hashable {
    public let operations: [String]
    public let aliases: [String]
    /// Methods exposed by the native app control socket alongside the daemon
    /// resource operation surface. Empty on other surfaces.
    public let appOperations: [String]
    public let appAliases: [String]
    public let row: String?
    public let editor: String?
    public let offered: Bool
    public let reason: String?

    public init(operations: [String], aliases: [String] = [], appOperations: [String] = [], appAliases: [String] = [],
                row: String? = nil, editor: String? = nil,
                offered: Bool? = nil, reason: String? = nil) {
        self.operations = operations
        self.aliases = aliases
        self.appOperations = appOperations
        self.appAliases = appAliases
        self.row = row
        self.editor = editor
        self.offered = offered ?? !operations.isEmpty
        self.reason = reason
    }

    var exportObject: [String: Any] {
        [
            "offered": offered,
            "operations": operations,
            "aliases": aliases,
            "app_operations": appOperations,
            "app_aliases": appAliases,
            "row": row.map { $0 as Any } ?? NSNull(),
            "editor": editor.map { $0 as Any } ?? NSNull(),
            "reason": reason.map { $0 as Any } ?? NSNull(),
        ]
    }
}

/// One descriptor's binding on each settings surface.
public nonisolated struct SettingSurfacePlan: Sendable, Hashable {
    public static let cliOperations = ["settings.list", "settings.get", "settings.set", "settings.reset"]
    public static let resetAliases = ["settings.unset"]
    public let palette: SettingSurfaceAvailability
    public let cli: SettingSurfaceAvailability
    public let mcp: SettingSurfaceAvailability
    public let socket: SettingSurfaceAvailability

    var exportObject: [String: Any] {
        [
            "palette": palette.exportObject,
            "cli": cli.exportObject,
            "mcp": mcp.exportObject,
            "socket": socket.exportObject,
        ]
    }
}

extension SettingDescriptor {
    /// The shared surface binding for this descriptor. CLI and socket writes
    /// still enforce the descriptor's value and managed-policy checks; MCP
    /// additionally limits writes to rows marked `agent_settable`.
    public var surfacePlan: SettingSurfacePlan {
        let palette: SettingSurfaceAvailability
        switch self.palette {
        case .exposed where isShownInCmuxNext:
            let row = "setting:\(id)"
            switch kind {
            case .toggle:
                palette = SettingSurfaceAvailability(operations: ["palette.toggleSetting"], row: row, editor: "toggle")
            default:
                // Choice, color, number and text rows are value pages in
                // SettingsPaletteSource rather than registered actions.
                palette = SettingSurfaceAvailability(operations: [], row: row, editor: "options", offered: true)
            }
        case .hidden(let reason):
            palette = SettingSurfaceAvailability(operations: [], reason: reason)
        case .exposed:
            palette = SettingSurfaceAvailability(operations: [], reason: "not_consumed_by_cmux_next")
        }

        let mcpRead = ["settings.list", "settings.get"]
        let mcpWrite = ["settings.set", "settings.reset"]
        let agentSettable = SettingsSchema.agentSettable(self) == true
        return SettingSurfacePlan(
            palette: palette,
            cli: SettingSurfaceAvailability(operations: SettingSurfacePlan.cliOperations, aliases: SettingSurfacePlan.resetAliases),
            mcp: SettingSurfaceAvailability(
                operations: mcpRead + (agentSettable ? mcpWrite : []),
                aliases: agentSettable ? SettingSurfacePlan.resetAliases : [],
                reason: agentSettable ? nil : "agent_settable_false"
            ),
            socket: SettingSurfaceAvailability(
                operations: SettingSurfacePlan.cliOperations,
                appOperations: ["settings.get", "settings.set", "settings.reset"],
                appAliases: SettingSurfacePlan.resetAliases
            )
        )
    }
}
