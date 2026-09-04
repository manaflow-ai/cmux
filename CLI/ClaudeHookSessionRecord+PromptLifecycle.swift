import CmuxAgentHooks

extension ClaudeHookSessionRecord {
    private var promptLifecycleState: AgentHookPromptLifecycleState {
        get {
            AgentHookPromptLifecycleState(
                depth: activePromptDepth,
                activeTurnID: activePromptTurnId,
                activeTurnIDs: activePromptTurnIds,
                lastTurnID: lastPromptTurnId
            )
        }
        set {
            activePromptDepth = newValue.depth
            activePromptTurnId = newValue.activeTurnID
            activePromptTurnIds = newValue.activeTurnIDs
            lastPromptTurnId = newValue.lastTurnID
        }
    }

    /// Starts an authoritative prompt in the persisted session projection.
    mutating func beginAuthoritativePrompt(turnId: String?) {
        var state = promptLifecycleState
        state.beginAuthoritativePrompt(turnID: turnId)
        promptLifecycleState = state
    }

    /// Closes all active prompt state while retaining the most recent turn id.
    mutating func endAuthoritativePrompt() {
        var state = promptLifecycleState
        state.endAuthoritativePrompt()
        promptLifecycleState = state
    }

    /// Clears active prompt fields while retaining the most recently observed turn identifier.
    mutating func clearActivePromptState() {
        var state = promptLifecycleState
        state.clearActivePromptState()
        promptLifecycleState = state
    }

    /// Clears active and completed prompt markers at a fresh session boundary.
    mutating func clearPromptStartState() {
        var state = promptLifecycleState
        state.clearPromptStartState()
        promptLifecycleState = state
    }
}

extension CMUXCLI.AgentHookDef {
    /// Derives prompt-depth semantics from the adapter's session boundary contract.
    var promptDepthPolicy: AgentHookPromptDepthPolicy {
        sessionEndIsTurnBoundary ? .authoritative : .balanced
    }
}
