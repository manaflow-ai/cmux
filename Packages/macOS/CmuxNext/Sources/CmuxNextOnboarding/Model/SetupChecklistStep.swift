import Foundation

/// One row of the sidebar's "Finish setting up" card (``SetupCardPageProvider/checklist``), as values the
/// sidebar draws: what the step is called, whether it is done or running, and what its click runs.
public struct SetupChecklistStep: Equatable, Sendable {
    /// The steps, in the card's order.
    public enum Kind: String, Sendable, CaseIterable {
        /// An agent that can answer: Claude Code or Codex installed and signed in.
        case agents
        /// Bring in chats from Claude Code and Codex (only when this Mac has some).
        case history
        /// A cmux account.
        case account
        /// This app's `cmux` command on the login PATH.
        case cli
    }

    public let kind: Kind
    /// The row's text: the step as an action ("Sign In to cmux").
    public let title: String
    /// The full-width button's text while this is the next step (an agent's login waiting on the person says
    /// "I’m Signed In" there).
    public let actionTitle: String
    public let done: Bool
    /// The step runs (an install): no second click.
    public let busy: Bool
    /// A click can run it (false for a `cmux` that is no cmux app's, or cmux running from its disk image).
    public let runnable: Bool
    /// The tooltip: what the step gives, or why it cannot run.
    public let help: String?

    public init(kind: Kind, title: String, actionTitle: String? = nil, done: Bool, busy: Bool = false, runnable: Bool = true, help: String? = nil) {
        self.kind = kind
        self.title = title
        self.actionTitle = actionTitle ?? title
        self.done = done
        self.busy = busy
        self.runnable = runnable
        self.help = help
    }

    /// A click runs it now.
    public var canRun: Bool { runnable && !done && !busy }
}
