public import CmuxNextActions

/// A control of the agent composer's bar that a shortcut opens, as a click on it does: each is one
/// catalog action (`agentPane.composer.*`, Ctrl-Opt-Cmd and a letter by default) and one page
/// command the agent page answers by opening that control (its `composer.*` command).
public nonisolated enum AgentComposerControl: String, CaseIterable, Sendable {
    /// The + menu: attach files, a screenshot, a mention, commands.
    case addMenu
    /// The folder (workspace) chip's menu.
    case chooseFolder
    /// The computer chip's menu: this Mac, another machine, the cloud.
    case chooseComputer
    /// The access mode chip's menu.
    case switchMode
    /// The Plan and Build toggle.
    case togglePlan
    /// The agent's other options.
    case agentOptions
    /// The context ring's usage card.
    case showContextUsage

    /// The catalog action whose shortcut runs it.
    public var actionID: ActionID { ActionID(rawValue: "agentPane.composer.\(rawValue)") }

    /// The command the agent page opens it on.
    var pageCommand: String { "composer.\(rawValue)" }
}
