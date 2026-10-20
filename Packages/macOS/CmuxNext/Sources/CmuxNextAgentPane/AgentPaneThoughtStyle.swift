public import CmuxNextDesign

/// How the agent pane draws thoughts, for comparing designs: `agentPane.debug.thoughtStyle`
/// (webviews conversation/thoughtStyle.ts).
public nonisolated enum AgentPaneThoughtStyle: String, Sendable, CaseIterable, TunableChoice {
    /// Today's: a muted "Thought" beside its text; notes between steps draw as replies.
    case plain
    /// A brain and the thought's first line, which opens to "Thoughts" over the whole text; notes
    /// between steps in an open "Worked for" draw the same way (Lucas 2026-10-17).
    case brain

    public var tunableTitle: String {
        switch self {
        case .plain: "Plain (Thought beside its text)"
        case .brain: "Brain (one line that opens to Thoughts)"
        }
    }
}
