import Foundation

/// Value description of a terminal panel's agent-launch context, rendered as the
/// newline-joined `key:value` string consumed by agent detection
/// (`TextBoxAgentDetection`) and the mobile terminal / chat RPC hosts.
///
/// The app builds this value from a panel's surface launch commands plus the
/// workspace's restored-agent snapshot and agent-PID maps, then reads
/// ``formatted``. Keeping the formatting here (a pure value transform) lets the
/// string builder live outside the workspace-content view while the app retains
/// the panel/workspace lookups that feed it.
public struct TerminalAgentContext: Sendable, Equatable {
    /// The surface's `initialCommand`, when the panel is a terminal panel.
    public var initialCommand: String?
    /// The surface's `tmuxStartCommand`, when the panel is a terminal panel.
    public var tmuxStartCommand: String?
    /// `rawValue` of the restored agent snapshot's kind for this panel, if any.
    public var restoredAgentKindRawValue: String?
    /// Agent PID keys recorded for this panel; emitted sorted.
    public var agentPIDKeys: Set<String>

    public init(
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        restoredAgentKindRawValue: String? = nil,
        agentPIDKeys: Set<String> = []
    ) {
        self.initialCommand = initialCommand
        self.tmuxStartCommand = tmuxStartCommand
        self.restoredAgentKindRawValue = restoredAgentKindRawValue
        self.agentPIDKeys = agentPIDKeys
    }

    /// Newline-joined `key:value` context string. Byte-faithful to the legacy
    /// `WorkspaceContentView.terminalAgentContext` builder: trims each part,
    /// drops empties, and joins with `\n`.
    public var formatted: String {
        var parts: [String] = []
        if let initialCommand {
            parts.append("initialCommand:\(initialCommand)")
        }
        if let tmuxStartCommand {
            parts.append("tmuxStartCommand:\(tmuxStartCommand)")
        }
        if let restoredAgentKindRawValue {
            parts.append("restoredAgent:\(restoredAgentKindRawValue)")
        }
        if !agentPIDKeys.isEmpty {
            for key in agentPIDKeys.sorted() {
                parts.append("agentPIDKey:\(key)")
            }
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
