import Foundation

/// The operations each settings descriptor exposes on the non-UI surfaces.
///
/// This is derived from the one native descriptor registry and exported with
/// `schemas/settings/settings-schema.json`; the daemon, CLI and MCP clients
/// consume that export instead of keeping their own key lists.
public nonisolated struct SettingSurfaceAvailability: Sendable, Hashable {
    public let operations: [String]
    public let reason: String?

    public init(operations: [String], reason: String? = nil) {
        self.operations = operations
        self.reason = reason
    }

    public var offered: Bool { !operations.isEmpty }

    var exportObject: [String: Any] {
        [
            "offered": offered,
            "operations": operations,
            "reason": reason.map { $0 as Any } ?? NSNull(),
        ]
    }
}

/// One descriptor's binding on each settings surface.
public nonisolated struct SettingSurfacePlan: Sendable, Hashable {
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
            palette = SettingSurfaceAvailability(operations: ["palette.setSetting"])
        case .hidden(let reason):
            palette = SettingSurfaceAvailability(operations: [], reason: reason)
        case .exposed:
            palette = SettingSurfaceAvailability(operations: [], reason: "not_consumed_by_cmux_next")
        }

        let cliAndSocket = ["settings.list", "settings.get", "settings.set", "settings.reset", "settings.unset"]
        let mcpRead = ["settings.list", "settings.get"]
        let mcpWrite = ["settings.set", "settings.reset", "settings.unset"]
        let agentSettable = SettingsSchema.agentSettable(self) == true
        return SettingSurfacePlan(
            palette: palette,
            cli: SettingSurfaceAvailability(operations: cliAndSocket),
            mcp: SettingSurfaceAvailability(
                operations: mcpRead + (agentSettable ? mcpWrite : []),
                reason: agentSettable ? nil : "agent_settable_false"
            ),
            socket: SettingSurfaceAvailability(operations: cliAndSocket)
        )
    }
}
