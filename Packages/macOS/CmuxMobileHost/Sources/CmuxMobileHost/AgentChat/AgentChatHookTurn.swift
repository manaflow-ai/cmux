public import CmuxAgentChat

/// Where a session's hooks last placed it relative to a turn.
///
/// A plugin or helper can call tools after a turn's `Stop`, and no `Stop`
/// follows those calls. The hook handler keeps the built-in status idle for
/// them (its `turnSettled` check); this is the same rule for session records.
public enum AgentChatHookTurn: Sendable, Equatable {
    /// No prompt or `Stop` has been seen for the session.
    case unknown
    /// A prompt opened a turn and no `Stop` has closed it.
    case open
    /// The last boundary is a `Stop`. Tool hooks that arrive now belong to no
    /// running turn.
    case settled

    /// The part of a hook event that matters to the turn.
    public enum Hook: Sendable, Equatable {
        case promptSubmitted
        case stopped
        case toolStarting
        case toolFinished
        /// Anything else, including a session start from a resume or a
        /// compaction, which is no turn boundary.
        case other
    }

    /// The turn after `hook`. Only a prompt opens a turn and only a `Stop`
    /// settles one, as in the hook store.
    public func after(_ hook: Hook) -> Self {
        switch hook {
        case .promptSubmitted:
            return .open
        case .stopped:
            return .settled
        case .toolStarting, .toolFinished, .other:
            return self
        }
    }

    /// Takes the hook store's word for a session no prompt or `Stop` has been
    /// seen for yet. A boundary seen live is newer than the store.
    public func adoptingStored(settled: Bool) -> Self {
        guard self == .unknown, settled else { return self }
        return .settled
    }

    /// The state a tool hook leaves a settled session in, or `nil` when the
    /// usual transitions apply.
    ///
    /// A starting tool changes nothing. A tool result returns the session to
    /// idle: such a call can raise a permission prompt, and its result ends
    /// that prompt whether it is still showing or typed input already moved
    /// the session to working.
    public func stateOverride(previous: ChatAgentState, hook: Hook) -> ChatAgentState? {
        guard self == .settled else { return nil }
        switch hook {
        case .toolStarting:
            return previous
        case .toolFinished:
            if case .ended = previous { return previous }
            return .idle
        case .promptSubmitted, .stopped, .other:
            return nil
        }
    }
}
