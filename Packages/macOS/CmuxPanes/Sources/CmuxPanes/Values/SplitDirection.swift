public import Bonsplit

/// Split direction for backwards compatibility with old API.
public enum SplitDirection: Sendable {
    /// Insert the new pane to the left of the source pane.
    case left
    /// Insert the new pane to the right of the source pane.
    case right
    /// Insert the new pane above the source pane.
    case up
    /// Insert the new pane below the source pane.
    case down

    /// Whether the split divides space horizontally (left/right).
    public var isHorizontal: Bool {
        self == .left || self == .right
    }

    /// The Bonsplit orientation for the new split.
    public var orientation: SplitOrientation {
        isHorizontal ? .horizontal : .vertical
    }

    /// If true, insert the new pane on the "first" side (left/top).
    /// If false, insert on the "second" side (right/bottom).
    public var insertFirst: Bool {
        self == .left || self == .up
    }

    /// The lowercase cardinal label for this direction (`left`/`right`/`up`/`down`).
    ///
    /// Byte-faithful home of the goto-split UI-test recorder's
    /// `recordSplitIfNeeded(direction:)` mapping switch.
    public var directionLabel: String {
        switch self {
        case .left:
            return "left"
        case .right:
            return "right"
        case .up:
            return "up"
        case .down:
            return "down"
        }
    }

    /// Parse a control-command split-direction token (`left`/`l`, `right`/`r`,
    /// `up`/`u`, `down`/`d`, case-insensitive), returning `nil` for any other
    /// value. This is the byte-faithful home of the legacy
    /// `TerminalController.parseSplitDirection(_:)` token table: the control
    /// socket, command palette, and move-tab paths all resolve a user-supplied
    /// direction string through this single source of truth.
    public init?(controlToken value: String) {
        switch value.lowercased() {
        case "left", "l":
            self = .left
        case "right", "r":
            self = .right
        case "up", "u":
            self = .up
        case "down", "d":
            self = .down
        default:
            return nil
        }
    }
}
