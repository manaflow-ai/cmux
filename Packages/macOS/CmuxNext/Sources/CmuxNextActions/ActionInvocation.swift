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

    /// This invocation with `confirm: true`.
    public func confirmed() -> ActionInvocation {
        var copy = self
        copy.arguments[ActionArgument.confirmName] = .bool(true)
        return copy
    }

    /// Set only by the registry after the person answered the user-only confirmation of a
    /// person-only action (cx-zk9t). No argument, key binding, page or socket caller can set
    /// it, so `confirm: true` never skips that confirmation.
    public internal(set) var isPersonConfirmed = false

    /// This invocation aimed at `target` (a confirmation's pinned object).
    public func retargeted(_ target: ActionTargetRef) -> ActionInvocation {
        var copy = self
        copy.target = target
        return copy
    }

    /// This invocation confirmed by the person (`gateDestructive` only).
    func personConfirmed() -> ActionInvocation {
        var copy = confirmed()
        copy.isPersonConfirmed = true
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
