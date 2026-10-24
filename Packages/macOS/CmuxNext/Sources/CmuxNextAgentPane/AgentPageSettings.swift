/// The Debug Settings an agent page gets with its theme (``AgentPaneTheme``): the chat width,
/// Codex-style tool runs, where the turn footer actions sit and where the live line draws. A
/// change repaints every window, so every open agent page resends its theme without a reload,
/// also before any agent pane has opened (the composition root follows it with
/// `ThemeStore.repaintAll(following:)`).
public nonisolated struct AgentPageSettings: Equatable, Sendable {
    /// `agent.chatWidth` (``AgentPaneTunables/chatWidth``).
    public var chatWidth: AgentPaneTunables.ChatWidth
    /// `agentPane.debug.codexToolRuns` (``AgentPaneTunables/codexToolRuns``).
    public var codexToolRuns: Bool
    /// `agentPane.debug.turnActionsPlacement` (``AgentPaneTunables/turnActionsPlacement``).
    public var turnActionsPlacement: AgentPaneTurnActionsPlacement
    /// `agentPane.debug.liveLineBelow` (``AgentPaneTunables/liveLineBelow``).
    public var liveLineBelow: Bool

    /// Reads the current values. Observable: each read is a tunable's observed value, so an
    /// Observation tracking around this init sees a change of any of them.
    @MainActor public init() {
        chatWidth = AgentPaneTunables.chatWidth.value
        codexToolRuns = AgentPaneTunables.codexToolRuns.value
        turnActionsPlacement = AgentPaneTunables.turnActionsPlacement.value
        liveLineBelow = AgentPaneTunables.liveLineBelow.value
    }
}
