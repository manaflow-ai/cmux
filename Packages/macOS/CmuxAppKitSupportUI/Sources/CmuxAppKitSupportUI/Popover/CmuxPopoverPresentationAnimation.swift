/// Selects the opening transition for an arrowless popover.
public enum CmuxPopoverPresentationAnimation: Equatable, Sendable {
    /// Uses the existing grouped-popover default: grouped menus open immediately.
    case automatic
    /// Uses the native opening transition unless Reduce Motion is enabled.
    case enabled
    /// Keeps the popover opening immediate, including for an ungrouped popover.
    case disabled

    func animates(isGrouped: Bool, reduceMotion: Bool) -> Bool {
        guard !reduceMotion else { return false }
        switch self {
        case .automatic:
            return !isGrouped
        case .enabled:
            return true
        case .disabled:
            return false
        }
    }
}
