public import Foundation

/// What the pointer leaving a shown card's target does.
public nonisolated enum HoverCardLeave: Hashable, Sendable {
    /// The card stays for the leave grace; a pointer heading into it or
    /// resting on it keeps it (the workspace card).
    case lingers
    /// The card hides as soon as the pointer leaves its target for anywhere
    /// but the card (a browser's tab preview). The card touches its target,
    /// so a pointer moving onto it keeps it while it rests there. Another
    /// target reached within `reshow` shows its card at once.
    case hides(reshow: Duration)

    /// The card hides as the pointer leaves its target (`hides`).
    public var hidesAtOnce: Bool {
        if case .hides = self { return true }
        return false
    }
}
