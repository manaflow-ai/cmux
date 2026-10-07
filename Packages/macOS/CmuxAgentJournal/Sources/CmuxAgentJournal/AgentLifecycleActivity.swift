/// A lifecycle transition worth surfacing to the user, as opposed to the
/// steady stream of tool calls and streamed output inside one turn.
///
/// Sidebar ordering uses this to decide which agent events may move a
/// workspace. It is derived from the reducer's combined phase for one surface
/// and agent before and after a live event, never from event prose.
public enum AgentLifecycleActivity: String, Sendable, Equatable, CaseIterable {
    /// A turn started from rest or after an error: the user submitted a new
    /// prompt.
    case promptSubmitted
    /// The agent finished its turn and is idle.
    case turnFinished
    /// The agent is blocked on the user (approval, question, or plan review).
    case needsInput
    /// The agent reported an error or a stop failure.
    case error

    /// Classifies one combined-phase transition.
    ///
    /// Staying in a phase (tool steps and streaming stay `running`), resuming
    /// after an approval (`needsInput` to `running`), a session ending (`nil`),
    /// and `unknown` are not meaningful.
    ///
    /// - Parameters:
    ///   - previous: The combined phase before the event, or `nil` when the
    ///     surface had no live session for the agent.
    ///   - current: The combined phase after the event, or `nil` when no live
    ///     session remains.
    /// - Returns: The meaningful activity, or `nil` when the transition should
    ///   not affect ordering.
    public static func classify(
        from previous: AgentLifecyclePhase?,
        to current: AgentLifecyclePhase?
    ) -> AgentLifecycleActivity? {
        guard let current, current != previous else { return nil }
        switch current {
        case .idle:
            return previous == .running ? .turnFinished : nil
        case .backgroundWorkPending:
            return nil
        case .needsInput:
            return .needsInput
        case .error:
            return .error
        case .running:
            switch previous {
            case nil, .unknown, .idle, .backgroundWorkPending: return .promptSubmitted
            case .needsInput, .error, .running: return nil
            }
        case .unknown:
            return nil
        }
    }

    /// Classifies the transition a live journal event caused.
    ///
    /// Explicit phase corrections (`stateChanged`) and session bookkeeping
    /// restore or tear down state rather than report new activity, so they
    /// never count, whatever phases they produce. A new prompt counts only
    /// for a turn start from rest or after an error; a turn start that
    /// resumes a surface waiting on input is the approval resuming work.
    ///
    /// - Parameters:
    ///   - kind: The kind of the event that was reduced.
    ///   - previous: The combined phase before the event.
    ///   - current: The combined phase after the event.
    /// - Returns: The meaningful activity, or `nil`.
    public static func classify(
        event kind: AgentJournalEventKind,
        from previous: AgentLifecyclePhase?,
        to current: AgentLifecyclePhase?
    ) -> AgentLifecycleActivity? {
        switch kind {
        case .stateChanged, .sessionStarted, .sessionEnded:
            return nil
        case .turnStarted:
            // A turn start from rest or after an error is the user's new
            // prompt. Some producers also send a turn start when an approval
            // resolves, so leaving needsInput stays quiet like
            // attentionResolved does.
            guard current == .running else { return nil }
            switch previous {
            case nil, .unknown, .idle, .backgroundWorkPending, .error: return .promptSubmitted
            case .needsInput, .running: return nil
            }
        default:
            let activity = classify(from: previous, to: current)
            // Only a turn start is a new prompt; a background child that
            // wakes an idle session is work, not the user asking for more.
            return activity == .promptSubmitted ? nil : activity
        }
    }
}
