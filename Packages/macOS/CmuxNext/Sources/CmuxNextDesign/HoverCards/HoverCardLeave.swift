public import Foundation

/// What the pointer leaving a shown card's target does.
public nonisolated enum HoverCardLeave: Hashable, Sendable {
    /// The card stays for the leave grace; a pointer heading into it or
    /// resting on it keeps it (the workspace card).
    case lingers
    /// The card hides at once, also with the pointer on it (nothing on it
    /// takes the pointer: a browser's tab preview). Another target reached
    /// within `reshow` shows its card at once.
    case hides(reshow: Duration)
}
