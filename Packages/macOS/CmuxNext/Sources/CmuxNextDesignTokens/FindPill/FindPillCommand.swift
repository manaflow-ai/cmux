/// What a find pill's keys and buttons ask its surface to do.
public enum FindPillCommand: Sendable, Equatable {
    /// Select the next match (Return, Cmd-G, the down chevron).
    case next
    /// Select the previous match (Shift-Return, Shift-Cmd-G, the up chevron).
    case previous
    /// Hide the pill and end the search (Escape, the close button).
    case close
}
