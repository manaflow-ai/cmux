/// A typed argument value.
public nonisolated enum ActionValue: Sendable, Hashable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case target(ActionTargetRef)

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var targetValue: ActionTargetRef? {
        if case .target(let value) = self { return value }
        return nil
    }
}

/// Who started an action run (plans/cmux-next/OWNERSHIP-PRINCIPLES.md):
/// only a user in this client may change this client's focus, selection
/// or scroll, unless the run asks for it (`focus: true`).
public nonisolated enum ActionOrigin: String, Sendable, Hashable, CaseIterable {
    /// Palette, menu, keyboard, click, drag in this app.
    case user
    case cli
    case mcp
    case script
    /// Another client (a phone, another Mac).
    case remote
    /// A first-party web page in this app (a control the page drew). Never the user's own gesture
    /// by itself: rules that need the user (destructive confirmation, view changes without a
    /// focus request) treat it like automation; only a native confirmation sheet raises a page
    /// call to `user` (PageCallContext.confirmed).
    case page
}

/// Everything a handler needs for one run: the target (right-clicked object,
/// CLI `--target`, or nil for "the focused one") and the collected arguments.
public nonisolated struct ActionInvocation: Sendable, Hashable {
    public var target: ActionTargetRef?
    public var arguments: [String: ActionValue]
    /// In-app runs are the user's; the control socket sets its caller's.
    public var origin: ActionOrigin
    /// The calling app preserved by the native provider, even during its user gesture.
    /// Nil for direct native/CLI/page calls; attribution never grants execution authority.
    public var callerApp: String?
    /// The run asked to change this client's view (`action.run` `focus: true`).
    public var focusRequested: Bool
    /// The context of the window whose key-down runs this (the key
    /// dispatcher), checked instead of the registry's process-wide context.
    public var keyContext: ActionContext?
    /// An agent opened this beside its chat (`caller.agent_session` with no
    /// target): the target is the column right of the chat, whose new tab is
    /// selected there while keyboard focus stays in the chat.
    public var besideCaller = false
    /// No column is right of the chat: the target is the chat, and the new
    /// tab moves into a new column right of it.
    public var newColumnBeside = false
    /// A person's click opened this beside the chat (the header's Changes, Preview or Files): its
    /// tab takes the keyboard focus where it lands, and its close gives it back to the chat. An
    /// agent's beside run never takes it. In-app only: the control socket never sets it.
    public var besideTakesFocus = false
    /// `action.run` `background: true`: a tab this run opens stays unselected in
    /// its pane, so the pane keeps showing what the person chose
    /// (plans/cmux-next/agent-browser-passkey-DESIGN.md 3.1).
    public var opensInBackground = false
    /// `caller.agent_session`: the agent chat whose CLI or cmux MCP server sent the run, nil for any
    /// other run. Its claim, like ``origin``: an action an agent may only ask a person for (Move to
    /// Cloud) asks in that chat instead of running.
    public var callerAgentSession: String?
    /// `caller.terminal_id`: the terminal whose cmux CLI sent the run (an agent running in a
    /// terminal), nil for any other run. Like ``callerAgentSession``, the caller's own claim.
    public var callerTerminal: String?
    /// A split that opens a terminal even where a person's split opens the New Tab page (the chat
    /// header's Terminal, cx-00n1). In-app only: the control socket never sets it.
    public var opensTerminal = false
    /// A run the sidebar sends for one of its rows (a row's close button or speaker, a middle-click,
    /// Delete on the selection): each row by itself, never widened to the selection. In-app only.
    public var closesRowOnly = false
    /// A person's unconfirmed Close Workspace: the destructive gate let it run at the press, and the
    /// handler asks about running programs itself, with the row still in place (`WorkspaceCloseFlow`).
    /// In-app only: the control socket never sets it.
    public var asksIfRunning = false
    /// The timestamp (`NSEvent.timestamp`, seconds of system uptime) of the key press or click
    /// that started this run, when the run went through a gate first (a confirmation sheet, the
    /// palette asking for an argument) and so may run in a later turn, outside that event's
    /// dispatch. The registry stamps it when the gate starts; the run's `action.*` signposts
    /// report its age when no input event is being dispatched at the run. Nil for every other run.
    public var inputTimestamp: Double?

    public init(target: ActionTargetRef? = nil, arguments: [String: ActionValue] = [:], origin: ActionOrigin = .user,
                focusRequested: Bool = false) {
        self.target = target
        self.arguments = arguments
        self.origin = origin
        self.focusRequested = focusRequested
    }

    /// Whether the run may change this client's focus, selection, shown
    /// workspace or key window.
    public var allowsViewChange: Bool {
        origin == .user || focusRequested || arguments["focus"]?.boolValue == true
    }

    public subscript(_ name: String) -> ActionValue? {
        arguments[name]
    }

    /// Whether a destructive action was confirmed (`confirm: true`).
    public var isConfirmed: Bool { arguments[ActionArgument.confirmName]?.boolValue == true }

    /// The sidebar's own close of workspace row `id` (`closesRowOnly`).
    public init(closingRow id: String) {
        self.init(target: ActionTargetRef(kind: .workspace, id: id))
        closesRowOnly = true
    }

    /// This invocation with `confirm: true`.
    public func confirmed() -> ActionInvocation {
        var copy = self
        copy.arguments[ActionArgument.confirmName] = .bool(true)
        return copy
    }

    /// The first argument's text form, for handlers that take one string.
    var legacyArgument: String? {
        let values = arguments.filter { $0.key != ActionArgument.confirmName }
        guard let value = values.values.first, values.count == 1 else { return nil }
        switch value {
        case .string(let text): return text
        case .int(let number): return String(number)
        case .bool(let flag): return String(flag)
        case .target(let ref): return ref.id
        }
    }
}
