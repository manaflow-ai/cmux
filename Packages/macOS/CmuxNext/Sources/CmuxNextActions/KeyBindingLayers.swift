/// Entries that do not come from the catalog or cmux.json: apps'
/// contributed keys and the user's keybindings.json. The table puts app
/// entries after the defaults and user entries after cmux.json's, each list
/// in its own order. User removals (`-<id>` entries) take matching default
/// and app entries out first.
public nonisolated struct KeyBindingLayers: Hashable, Sendable {
    public var app: [KeyBinding]
    public var user: [KeyBinding]
    public var removals: [KeyBindingRemoval]

    public init(app: [KeyBinding] = [], user: [KeyBinding] = [], removals: [KeyBindingRemoval] = []) {
        self.app = app
        self.user = user
        self.removals = removals
    }
}

/// A negative entry (`"command": "-nextSurface"`): removes the default and
/// app entries of `command` on `keys` (every key when nil) whose `when`
/// equals `when` (any `when` when `.any`). The action's other keys stay.
public nonisolated struct KeyBindingRemoval: Hashable, Sendable {
    public enum WhenMatch: Hashable, Sendable {
        case any
        /// Structurally equal; nil is an entry without a `when`.
        case exactly(WhenClause?)
    }

    public var command: ActionID
    public var keys: [Shortcut]?
    public var when: WhenMatch

    public init(command: ActionID, keys: [Shortcut]? = nil, when: WhenMatch = .any) {
        self.command = command
        self.keys = keys
        self.when = when
    }

    public func removes(_ entry: KeyBinding) -> Bool {
        guard entry.command == command, keys == nil || entry.keys == keys else { return false }
        switch when {
        case .any: return true
        case .exactly(let clause): return entry.when == clause
        }
    }
}
