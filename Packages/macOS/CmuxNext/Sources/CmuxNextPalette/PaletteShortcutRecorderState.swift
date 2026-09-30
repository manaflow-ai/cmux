public import CmuxNextActions

/// A chord waiting for the user's choice (a conflict, or a note to read).
public enum PaletteShortcutPending: Equatable, Sendable {
    case set(Shortcut, owners: [ActionID], canKeepBoth: Bool, canReplace: Bool = true)
    case restoreDefault(Shortcut, owners: [ActionID], canKeepBoth: Bool, canReplace: Bool = true)

    var owners: [ActionID] {
        switch self {
        case .set(_, let owners, _, _), .restoreDefault(_, let owners, _, _): owners
        }
    }

    var canKeepBoth: Bool {
        switch self {
        case .set(_, let owners, let keep, _), .restoreDefault(_, let owners, let keep, _): keep && !owners.isEmpty
        }
    }

    var canReplace: Bool {
        switch self {
        case .set(_, _, _, let replace), .restoreDefault(_, _, _, let replace): replace
        }
    }
}

/// The inline recorder's state, shown over the palette (Cmd-K on an action).
public struct PaletteShortcutRecorderState: Equatable, Sendable {
    public let actionID: ActionID
    public let actionTitle: String
    /// The action's shortcut before this edit.
    public var currentKeycaps: [String]?
    /// The last chord pressed.
    public var recorded: Shortcut?
    /// Why the chord was refused, what it collides with, or a note.
    public var message: String?
    public var pending: PaletteShortcutPending?
    public var hasDefault: Bool

    /// The choices the recorder offers now, in order.
    public var options: [PaletteShortcutOption] {
        guard let pending else { return [.cancel, .remove, .restoreDefault] }
        var options: [PaletteShortcutOption] = []
        if pending.owners.isEmpty { options.append(.save) } else if pending.canReplace { options.append(.replace) }
        if pending.canKeepBoth { options.append(.keepBoth) }
        options.append(.cancel)
        return options
    }
}
