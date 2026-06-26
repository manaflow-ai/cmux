/// Decides whether the palette must dismiss itself before running a command,
/// for the commands that synchronously move focus (the fork-conversation
/// commands and browser focus mode) so the palette's `makeFirstResponder(nil)`
/// cannot clear that focus afterward.
public struct CommandPaletteDismissBeforeRunPolicy: Sendable {
    /// The identifier of the command about to run.
    public let commandId: String

    /// Captures the command identifier to evaluate.
    public init(commandId: String) {
        self.commandId = commandId
    }

    /// Whether the palette should dismiss before running the command.
    public var shouldDismissBeforeRun: Bool {
        switch commandId {
        case "palette.forkAgentConversationRight",
             "palette.forkAgentConversationLeft",
             "palette.forkAgentConversationTop",
             "palette.forkAgentConversationBottom",
             "palette.forkAgentConversationNewTab",
             "palette.forkAgentConversationNewWorkspace",
             // Entering browser focus mode focuses the web view synchronously;
             // dismiss the palette first so its makeFirstResponder(nil) doesn't
             // clear that focus and leave focus mode active without key routing.
             "palette.browserFocusMode":
            return true
        default:
            return false
        }
    }
}
