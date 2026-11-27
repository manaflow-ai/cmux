public import CmuxAgentQuestion

/// One thing a ``ChiefBrain`` reports during a turn.
public enum ChiefTurnEvent: Sendable, Equatable {
    /// The CLI session id; the owner resumes it on the conversation's next turn.
    case session(String)
    /// More assistant text for the current segment (shown as a live draft).
    case textDelta(String)
    /// One assistant text block finished; its text becomes one Chief bubble.
    case textSegmentEnd
    /// A tool call started; it shows as a work message with status running.
    case toolStarted(id: String, title: String, detail: String?)
    /// The tool call `id` finished; its work message turns done or failed.
    case toolFinished(id: String, ok: Bool, preview: String?)
    /// The Chief asks the user a question; it posts as a question part.
    case question(AgentQuestion)
    /// The turn needs the user's approval; it posts as an approval part.
    /// The owner answers through ``ChiefBrain/respond(toApproval:choice:conversation:)``.
    case approvalRequested(id: String, prompt: String, options: [String])
    /// A flow's result card (a `cmux-result` block, ``ChiefStructuredBlocks``):
    /// it posts as a work part whose host is the machine, with an Open action.
    case result(ChiefResultCard)
    /// Token counts so far; the owner keeps the last one for the turn's
    /// ``ChiefTurnStats/cacheHitRate``.
    case usage(ChiefTurnUsage)
    /// The turn ended normally.
    case finished
    /// The turn failed; the message is shown to the user.
    case failed(String)
}
