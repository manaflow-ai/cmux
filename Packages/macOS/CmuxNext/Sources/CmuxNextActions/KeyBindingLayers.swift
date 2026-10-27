/// Entries that do not come from the catalog or cmux.json: apps'
/// contributed keys, the user's keybindings.json and the Ghostty config's
/// keybinds. The table puts app entries after the defaults and user entries
/// after cmux.json's, each list in its own order; `.ghosttyFallback` entries
/// go first and `.ghostty` entries after the app entries (GHOSTTY-CONFIG).
/// User removals (`-<id>` entries) take matching default and app entries
/// out first; they never remove a Ghostty keybind (the user's own config).
public nonisolated struct KeyBindingLayers: Hashable, Sendable {
    public var app: [KeyBinding]
    public var user: [KeyBinding]
    public var removals: [KeyBindingRemoval]
    /// `.ghosttyFallback` and `.ghostty` entries (`KeyBindingLoader.loadGhostty`).
    public var ghostty: [KeyBinding] { didSet { usersGhosttyKeys = Self.usersKeys(ghostty, ghosttyClaims) } }
    /// Keys the user's Ghostty config maps to a terminal action or unbinds:
    /// no cmux default entry runs on them (cmux.json entries still do).
    public var ghosttyClaims: [Shortcut] { didSet { usersGhosttyKeys = Self.usersKeys(ghostty, ghosttyClaims) } }
    /// The user's own Ghostty keys: ``ghosttyClaims`` and the keys of single-key
    /// `.ghostty` entries (never a `.ghosttyFallback` default). Rebuilt when
    /// either changes, so a terminal key looks it up in O(1).
    public private(set) var usersGhosttyKeys: Set<Shortcut>

    public init(app: [KeyBinding] = [], user: [KeyBinding] = [], removals: [KeyBindingRemoval] = [], ghostty: [KeyBinding] = [],
                ghosttyClaims: [Shortcut] = []) {
        self.app = app
        self.user = user
        self.removals = removals
        self.ghostty = ghostty
        self.ghosttyClaims = ghosttyClaims
        usersGhosttyKeys = Self.usersKeys(ghostty, ghosttyClaims)
    }

    private static func usersKeys(_ ghostty: [KeyBinding], _ claims: [Shortcut]) -> Set<Shortcut> {
        var keys = Set(claims)
        for entry in ghostty where entry.source == .ghostty && entry.keys.count == 1 {
            keys.insert(entry.keys[0])
        }
        return keys
    }
}

/// A negative entry (`"command": "-nextSurface"`): removes the default and
/// app entries of `command` on `keys` (every key when nil) whose `when`
/// equals `when` (any `when` when `.any`). The action's other keys stay.
public nonisolated struct KeyBindingRemoval: Hashable, Sendable {
    public enum WhenMatch: Hashable, Sendable {
        case any
        /// The same clause as text (`WhenClause.text` is canonical: a
        /// one-clause or nested `&&` reads as its parts); nil is an entry
        /// without a `when`.
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
        case .exactly(let clause): return entry.when?.text == clause?.text
        }
    }
}
