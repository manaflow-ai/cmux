/// A chord waiting for the user's choice (a conflict, or a note to read).
public enum ShortcutRecorderPending: Equatable, Sendable {
    case set(Shortcut, owners: [ActionID], canKeepBoth: Bool, canReplace: Bool = true)
    case restoreDefault(Shortcut, owners: [ActionID], canKeepBoth: Bool, canReplace: Bool = true)

    public var owners: [ActionID] {
        switch self {
        case .set(_, let owners, _, _), .restoreDefault(_, let owners, _, _): owners
        }
    }

    public var canKeepBoth: Bool {
        switch self {
        case .set(_, let owners, let keep, _), .restoreDefault(_, let owners, let keep, _): keep && !owners.isEmpty
        }
    }

    public var canReplace: Bool {
        switch self {
        case .set(_, _, _, let replace), .restoreDefault(_, _, _, let replace): replace
        }
    }
}

/// A choice the recorder offers (click, or its key).
public enum ShortcutRecorderOption: Equatable, Sendable {
    case save, replace, keepBoth, cancel, remove, restoreDefault
}

/// The recorder's state for one action: shown inline in the palette (Cmd-K
/// on an action) and on a row of the Settings window's Keyboard section.
public struct ShortcutRecorderState: Equatable, Sendable {
    public let actionID: ActionID
    public let actionTitle: String
    /// The action's shortcut before this edit.
    public var currentKeycaps: [String]?
    /// The last chord pressed.
    public var recorded: Shortcut?
    /// Why the chord was refused, what it collides with, or a note.
    public var message: String?
    public var pending: ShortcutRecorderPending?
    public var hasDefault: Bool

    public init(actionID: ActionID, actionTitle: String, currentKeycaps: [String]? = nil, recorded: Shortcut? = nil,
                message: String? = nil, pending: ShortcutRecorderPending? = nil, hasDefault: Bool) {
        self.actionID = actionID
        self.actionTitle = actionTitle
        self.currentKeycaps = currentKeycaps
        self.recorded = recorded
        self.message = message
        self.pending = pending
        self.hasDefault = hasDefault
    }

    /// The choices the recorder offers now, in order.
    public var options: [ShortcutRecorderOption] {
        guard let pending else { return [.cancel, .remove, .restoreDefault] }
        var options: [ShortcutRecorderOption] = []
        if pending.owners.isEmpty { options.append(.save) } else if pending.canReplace { options.append(.replace) }
        if pending.canKeepBoth { options.append(.keepBoth) }
        options.append(.cancel)
        return options
    }
}
