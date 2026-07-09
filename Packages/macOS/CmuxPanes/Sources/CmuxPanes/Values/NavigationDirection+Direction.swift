public import Bonsplit

extension NavigationDirection {
    /// The lowercase cardinal label for this direction (`left`/`right`/`up`/`down`).
    ///
    /// Byte-faithful home of the goto-split UI-test recorder's
    /// `recordMoveIfNeeded(direction:)` mapping switch.
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
}
