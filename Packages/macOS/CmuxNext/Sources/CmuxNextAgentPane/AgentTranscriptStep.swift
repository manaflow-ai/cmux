/// The agent chat's transcript steps: each is a catalog action (``actionID``) the app binds to the
/// focused chat, and a page command (``pageCommand``) the page turns into the window event its
/// thread minimap handles (App.tsx `command`).
public nonisolated enum AgentTranscriptStep: String, CaseIterable, Sendable {
    /// Ctrl-Opt-Up and Ctrl-Opt-Down: the prompt before or after the one being read (cx-f7c).
    case previousTurn, nextTurn
    /// No default key: the bookmarked prompt before or after the one being read.
    case previousBookmarkedPrompt, nextBookmarkedPrompt

    public var actionID: String { "agentPane.\(rawValue)" }
    public var pageCommand: String { rawValue }
}
