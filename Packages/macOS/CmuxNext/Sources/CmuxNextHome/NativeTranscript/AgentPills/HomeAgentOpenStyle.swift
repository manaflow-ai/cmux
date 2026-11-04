#if DEBUG
import Foundation

/// DEBUG ONLY: what a click on an agent's pill does in the Agent Messages Playground (user 2026-11-03,
/// msg 19960: "when i click, it opens it to the right … a button in the chat, to go to its actual workspace …
/// a workspace inside a tab … i want to see different versions to see how it feels"). The labels are
/// DEV-only English.
enum HomeAgentOpenStyle: Int, CaseIterable, Sendable {
    case rightPane, workspaceTab, peek, commandClick, inline, replace, floating

    /// A short name for the playground's picker.
    var title: String {
        switch self {
        case .rightPane: "A. Right pane with tabs"
        case .workspaceTab: "B. Workspace in a tab"
        case .peek: "C. Peek popover"
        case .commandClick: "D. ⌘-click to workspace"
        case .inline: "E. Inline expand"
        case .replace: "F. Replace the chat"
        case .floating: "G. Floating window"
        }
    }

    /// What the variant does, one sentence, for the playground's caption.
    var caption: String {
        switch self {
        case .rightPane: "The agent's chat opens in a right pane, one tab per agent, with Go to workspace in its header."
        case .workspaceTab: "The right pane's tab holds the agent's whole workspace: its chat beside its terminal."
        case .peek: "A popover at the pill shows the task and the latest reply; Open moves it to the right pane."
        case .commandClick: "A click opens the right pane; ⌘-click goes straight to the agent's workspace."
        case .inline: "A click opens the agent messages under the pills, in the Chief's chat (no pane)."
        case .replace: "The agent's chat takes the Chief's place, with a back button, like a pushed page."
        case .floating: "The agent's chat opens in a small floating window that stays over the app."
        }
    }
}
#endif
