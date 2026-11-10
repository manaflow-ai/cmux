/// What moved the focus. A pointer click never centers: the column under the
/// pointer only scrolls far enough to be fully visible, so content does not
/// slide away under the click (also in `always` mode).
public nonisolated enum ColumnFocusSource: Hashable, Sendable {
    case keyboard
    case pointer
    /// Focus decided elsewhere (CLI, daemon, a new pane): same as keyboard.
    case programmatic
    /// Focus the scroll itself moved (end of a trackpad gesture or a wheel
    /// notch): the column is already visible, nothing scrolls.
    case scroll
}

extension ColumnFocusSource {
    /// A pane-navigation action's move: the person's keys, or the same action the CLI, an agent or
    /// a script ran, which nobody keyed and which earns no focus ring (`LayoutModel.focusRingEarned`).
    public static func keyMove(byPerson: Bool) -> ColumnFocusSource { byPerson ? .keyboard : .programmatic }
}
