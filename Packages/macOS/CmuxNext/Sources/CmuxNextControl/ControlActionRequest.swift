public import CmuxNextSettings

/// A validated `action.run` request: the canonical action ID, the target,
/// and arguments already checked against the action's schema.
public struct ControlActionRequest: Sendable, Hashable {
    public var actionID: String
    public var target: ControlTargetRef?
    public var arguments: [String: ControlValue]
    /// `action.run` `origin` (`user`, `cli`, `mcp`, `script`, `remote`);
    /// absent means `cli`.
    public var origin: String
    /// Native-provider app attribution, independent of the gesture's origin.
    /// Never populated from action params or interpreted as an execution grant.
    public var callerApp: String?
    /// `action.run` `focus: true`: change this client's view anyway.
    public var focus: Bool
    /// `action.run` `background: true`: a tab the run opens stays unselected in
    /// its pane, so the pane keeps showing what the person chose
    /// (plans/cmux-next/agent-browser-passkey-DESIGN.md 3.1).
    public var background = false
    /// The router aimed this run at the column right of its agent caller's
    /// chat (`caller.agent_session`, beside_caller in ControlCaller).
    /// `caller.agent_session`: the agent that sent the run (ControlCaller).
    public var callerAgentSession: String?
    /// `caller.terminal_id`: the terminal whose cmux CLI sent the run (an agent that runs in a
    /// terminal, not in an agent chat), nil for any other run.
    public var callerTerminal: String?
    /// `caller.home_chat`: a Chief turn, whose chat is the Home chat (ControlCaller).
    public var callerHomeChat = false
    public var besideCaller = false
    /// That column does not exist: the target is the chat itself, and the
    /// handler moves the new tab into a new column right of it.
    public var newColumnBeside = false

    public init(actionID: String, target: ControlTargetRef? = nil, arguments: [String: ControlValue] = [:], origin: String = "cli",
                focus: Bool = false) {
        self.actionID = actionID
        self.target = target
        self.arguments = arguments
        self.origin = origin
        self.focus = focus
    }
}

/// What happened when the executor tried to run an action.
public enum ControlActionOutcome: Sendable, Hashable {
    case ran
    case unknownAction
    /// The catalog has the action but the App bound no handler.
    case notBound
    /// Its required context is missing (for example a browser action with
    /// no browser focused).
    case unavailable
    /// Its handler's `isEnabled` predicate refused.
    case disabled
    /// The action cannot run, with a typed reason: a missing daemon
    /// capability, an unported feature, or a target it cannot act on.
    case refused(String)
    /// An explicit target names nothing (`not_found`), with the reason.
    case notFound(String)
    /// An administrator turned off the action's feature (`DisabledFeatures`).
    case featureDisabled(String)
    /// A destructive action ran without `confirm: true`; nothing happened.
    case confirmationRequired
}
