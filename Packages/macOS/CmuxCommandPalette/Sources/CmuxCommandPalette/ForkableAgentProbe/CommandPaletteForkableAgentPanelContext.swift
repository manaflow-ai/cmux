public import Foundation

/// The focused-terminal-panel inputs ``CommandPaletteForkableAgentProbeCoordinator``
/// needs to refresh a panel's forkable-agent availability.
///
/// The host resolves the focused panel into this value before calling
/// ``CommandPaletteForkableAgentProbeCoordinator/refreshAvailabilityIfNeeded(scopeIsCommands:panelContext:)``,
/// keeping the live workspace/panel reads on the host side. `Snapshot` is the
/// host's restorable agent-snapshot value type.
public struct CommandPaletteForkableAgentPanelContext<Snapshot: Sendable>: Sendable {
    /// The focused panel's workspace id.
    public let workspaceId: UUID
    /// The focused panel's id.
    public let panelId: UUID
    /// Whether the panel is backed by a remote terminal surface.
    public let isRemoteTerminal: Bool
    /// The restorable agent snapshot bound to the panel, if any.
    public let fallbackSnapshot: Snapshot?

    /// Creates a panel context.
    public init(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteTerminal: Bool,
        fallbackSnapshot: Snapshot?
    ) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.isRemoteTerminal = isRemoteTerminal
        self.fallbackSnapshot = fallbackSnapshot
    }
}
