/// One keybinding: a key sequence that runs an action with arguments while
/// its `when` clause holds (plans/cmux-next/keybindings.md section 4).
public nonisolated struct KeyBinding: Hashable, Sendable {
    /// Where the entry comes from. Later sources take precedence.
    public enum Source: Int, Comparable, Sendable, CaseIterable {
        case `default` = 0
        case app = 1
        case user = 2

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        public var name: String {
            switch self {
            case .default: "default"
            case .app: "app"
            case .user: "user"
            }
        }
    }

    /// One to ``KeyBindingTable/maxSequenceLength`` keys.
    public var keys: [Shortcut]
    public var command: ActionID
    /// The digit of a numbered family (`⌘1…9`): the action's first argument.
    public var argument: String?
    /// Typed arguments for the action.
    public var arguments: [String: ActionValue]
    /// Nil: always.
    public var when: WhenClause?
    public var source: Source

    public init(keys: [Shortcut], command: ActionID, argument: String? = nil, arguments: [String: ActionValue] = [:],
                when: WhenClause? = nil, source: Source = .default) {
        self.keys = keys
        self.command = command
        self.argument = argument
        self.arguments = arguments
        self.when = when
        self.source = source
    }

    public func applies(in context: KeyContext) -> Bool { when?.evaluate(context) ?? true }
}

/// The ordered binding table: defaults, then app entries, then user
/// entries; the last entry that matches the keys, whose `when` holds and
/// whose action can run, wins. Pure: the caller supplies the context keys
/// and whether an action can run now.
public nonisolated struct KeyBindingTable: Sendable {
    public static let maxSequenceLength = 4

    /// In precedence order: a later entry wins over an earlier one.
    public let entries: [KeyBinding]
    /// Entry indexes by first key, ascending.
    private let byFirstKey: [Shortcut: [Int]]

    public init(_ entries: [KeyBinding]) {
        self.entries = entries
        var index: [Shortcut: [Int]] = [:]
        for (offset, entry) in entries.enumerated() {
            guard let first = entry.keys.first, entry.keys.count <= Self.maxSequenceLength else { continue }
            index[first, default: []].append(offset)
        }
        byFirstKey = index
    }

    /// Why an entry won or lost a resolution (`keybinding.resolve`).
    public enum Verdict: String, Sendable {
        case won
        /// Its `when` clause is false here.
        case whenFalse
        /// Its action cannot run now (no handler, disabled, unavailable).
        case notRunnable
        /// A later entry won.
        case shadowed
    }

    public struct Candidate: Hashable, Sendable {
        public var binding: KeyBinding
        public var verdict: Verdict
    }

    public struct Resolution: Sendable {
        public var winner: KeyBinding?
        /// Every entry for exactly these keys, latest first.
        public var candidates: [Candidate]
    }

    /// The entry `keys` runs in `context`, with every candidate's verdict.
    public func resolve(_ keys: [Shortcut], in context: KeyContext, isRunnable: (ActionID) -> Bool) -> Resolution {
        var resolution = Resolution(winner: nil, candidates: [])
        guard let first = keys.first else { return resolution }
        for offset in (byFirstKey[first] ?? []).reversed() where entries[offset].keys == keys {
            let entry = entries[offset]
            let verdict: Verdict
            if resolution.winner != nil {
                verdict = .shadowed
            } else if !entry.applies(in: context) {
                verdict = .whenFalse
            } else if !isRunnable(entry.command) {
                verdict = .notRunnable
            } else {
                verdict = .won
                resolution.winner = entry
            }
            resolution.candidates.append(Candidate(binding: entry, verdict: verdict))
        }
        return resolution
    }

    /// Whether `prefix` starts a longer entry that could run here: the next
    /// key may complete a chord.
    public func continues(_ prefix: [Shortcut], in context: KeyContext, isRunnable: (ActionID) -> Bool) -> Bool {
        guard let first = prefix.first else { return false }
        return (byFirstKey[first] ?? []).contains { offset in
            let entry = entries[offset]
            return entry.keys.count > prefix.count && Array(entry.keys.prefix(prefix.count)) == prefix
                && entry.applies(in: context) && isRunnable(entry.command)
        }
    }

    /// One key that may follow an armed prefix (the which-key overlay).
    public struct NextKey: Hashable, Sendable {
        public var key: Shortcut
        /// The entry the key runs now, else the first entry for exactly
        /// these keys whatever its `when`; nil when the key only leads on.
        public var binding: KeyBinding?
        /// Longer entries continue after this key.
        public var continues: Bool
        /// Pressing the key does something here: it runs an action or arms
        /// a longer chord whose action can run.
        public var isRunnable: Bool
    }

    /// Every key under `prefix`, once, ordered by key: what it runs in
    /// `context` and whether more keys follow. A numbered family (entries
    /// with a digit argument) is listed once, by its `1`.
    public func nextKeys(after prefix: [Shortcut], in context: KeyContext, isRunnable: (ActionID) -> Bool) -> [NextKey] {
        var grouped: [Shortcut: [KeyBinding]] = [:]
        for entry in entries(after: prefix) where entry.keys.count <= Self.maxSequenceLength {
            var key = entry.keys[prefix.count]
            if entry.keys.count == prefix.count + 1, entry.argument != nil, ("1"..."9").contains(key.key) {
                key = Shortcut("1", modifiers: key.modifiers)
            }
            grouped[key, default: []].append(entry)
        }
        return grouped.map { key, group in
            let keys = prefix + [key]
            let exact = group.filter { $0.keys.count == keys.count }
            let winner = resolve(keys, in: context, isRunnable: isRunnable).winner
            let continues = group.count > exact.count
            let runnable = winner != nil || (continues && self.continues(keys, in: context, isRunnable: isRunnable))
            return NextKey(key: key, binding: winner ?? exact.first, continues: continues, isRunnable: runnable)
        }.sorted { ($0.key.key, $0.key.modifiers.rawValue) < ($1.key.key, $1.key.modifiers.rawValue) }
    }

    /// Every entry under `prefix`, whatever its `when` clause (the which-key
    /// overlay lists what a prefix offers).
    public func entries(after prefix: [Shortcut]) -> [KeyBinding] {
        guard let first = prefix.first else { return [] }
        return (byFirstKey[first] ?? []).map { entries[$0] }.filter {
            $0.keys.count > prefix.count && Array($0.keys.prefix(prefix.count)) == prefix
        }
    }
}

/// Entries that do not come from the catalog or cmux.json: apps'
/// contributed keys and the user's keybindings.json. The table puts app
/// entries after the defaults and user entries after cmux.json's, each list
/// in its own order.
public nonisolated struct KeyBindingLayers: Hashable, Sendable {
    public var app: [KeyBinding]
    public var user: [KeyBinding]

    public init(app: [KeyBinding] = [], user: [KeyBinding] = []) {
        self.app = app
        self.user = user
    }
}
