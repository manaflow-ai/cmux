import Foundation

/// One named value of an enumeration argument.
public nonisolated struct ActionEnumCase: Sendable, Hashable {
    /// Stable value used by the CLI and handlers (`--arg color=sage`).
    public let value: String
    public let title: String

    public init(value: String, title: String) {
        self.value = value
        self.title = title
    }
}

/// The type of an action argument.
public nonisolated enum ActionArgumentKind: Sendable, Hashable {
    case string
    case int(ClosedRange<Int>?)
    case bool
    case enumeration([ActionEnumCase])
    /// A reference to an object of this kind, chosen from a list.
    case target(ActionTargetKind)
}

/// One typed argument in an action's schema. The palette collects arguments
/// inline in order; the CLI takes them as `--arg name=value`; handlers read
/// them from `ActionInvocation.arguments`.
public nonisolated struct ActionArgument: Sendable, Hashable {
    /// Stable key (`--arg <name>=`).
    public let name: String
    public var title: String
    public var kind: ActionArgumentKind
    public var isRequired: Bool
    /// A free-text argument with a searchable list of known values (all
    /// Ghostty themes); nil for plain text.
    public var suggestions: ActionSuggestions?
    /// The target's new name (a rename): a prompt for it starts from the
    /// target's current name, selected.
    public var isTargetName = false

    public init(name: String, title: String, kind: ActionArgumentKind, isRequired: Bool = true, suggestions: ActionSuggestions? = nil) {
        self.name = name
        self.title = title
        self.kind = kind
        self.isRequired = isRequired
        self.suggestions = suggestions
    }

    /// Name of the bool argument a destructive action takes (`--confirm`).
    public nonisolated static let confirmName = "confirm"

    /// A copy that may be omitted.
    public var optional: ActionArgument {
        var copy = self
        copy.isRequired = false
        return copy
    }

    /// A copy that names the action's target (`isTargetName`).
    public var renamingTarget: ActionArgument {
        var copy = self
        copy.isTargetName = true
        return copy
    }

    /// Parses a CLI or palette string into a value of this argument's kind.
    /// Nil when the text does not fit the kind.
    public func parse(_ text: String) -> ActionValue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .string:
            return .string(text)
        case .int(let range):
            guard let value = Int(trimmed), range?.contains(value) ?? true else { return nil }
            return .int(value)
        case .bool:
            switch trimmed.lowercased() {
            case "true", "yes", "on", "1": return .bool(true)
            case "false", "no", "off", "0": return .bool(false)
            default: return nil
            }
        case .enumeration(let cases):
            guard cases.contains(where: { $0.value == trimmed }) else { return nil }
            return .string(trimmed)
        case .target(let targetKind):
            if let ref = ActionTargetRef(parsing: trimmed), ref.kind == targetKind { return .target(ref) }
            guard !trimmed.isEmpty else { return nil }
            return .target(ActionTargetRef(kind: targetKind, id: trimmed))
        }
    }
}
