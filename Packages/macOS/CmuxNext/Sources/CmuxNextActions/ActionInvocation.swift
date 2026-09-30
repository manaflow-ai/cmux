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

/// Everything a handler needs for one run: the target (right-clicked object,
/// CLI `--target`, or nil for "the focused one") and the collected arguments.
public nonisolated struct ActionInvocation: Sendable, Hashable {
    public var target: ActionTargetRef?
    public var arguments: [String: ActionValue]

    public init(target: ActionTargetRef? = nil, arguments: [String: ActionValue] = [:]) {
        self.target = target
        self.arguments = arguments
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
