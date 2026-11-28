/// The focus successor rules for every close kind (plans/cmux-next/close-focus.md).
/// One pure function per kind; tab selection and window selection call
/// these, and the focus reducer in cmux-focus-core runs the pane rule; nothing
/// else decides a successor.
///
/// Shared contract (checked by FocusAfterCloseModelCheckTests and
/// plans/cmux-next/formal/closefocus.tla):
/// - C1 a focus that survives stays (closing an unfocused item, or a close
///   by another client or the daemon of an item this client did not focus,
///   never moves focus),
/// - C2 the successor is a surviving, shown item,
/// - C3 the successor is nil only when no shown item survives,
/// - C4 deterministic: the result depends only on the arguments.
public nonisolated enum FocusAfterClose {
    /// The item in `old` order to focus after `closed` left: the next
    /// surviving one after it, else the previous one (`preferNext`), or
    /// the reverse. nil when `closed` was not in `old` or nothing survives.
    public static func neighbor<ID: Hashable>(of closed: ID, in old: [ID], preferNext: Bool,
                                              where survives: (ID) -> Bool) -> ID? {
        guard let index = old.firstIndex(of: closed) else { return nil }
        let after = old[(index + 1)...].first(where: survives)
        let before = old[..<index].last(where: survives)
        return preferNext ? (after ?? before) : (before ?? after)
    }

    /// Generic resolution: `focused` if it survives (C1), else `successor`
    /// when that survives, else the first surviving item of `fallback`.
    public static func resolve<ID: Hashable>(focused: ID?, survives: (ID) -> Bool, successor: ID?, fallback: [ID]) -> ID? {
        if let focused, survives(focused) { return focused }
        if let successor, survives(successor) { return successor }
        return fallback.first(where: survives)
    }

    // MARK: Panes

    // The pane successor rule (`pane`) lives in cmux-focus-core
    // (cmux-tui/crates/cmux-focus-core, `close_focus::pane`): the focus
    // reducer that runs it is there.

    // MARK: Tabs

    /// The tab a pane selects after `selected` closed: the
    /// next shown tab after it, else the previous shown one. `old` is the
    /// strip order before the close, `shown` the tabs that survive and are
    /// not hidden (a collapsed group's members are hidden). When no shown
    /// tab survives, the first surviving tab (its group then expands).
    public static func tab<ID: Hashable>(selected: ID?, old: [ID], surviving: [ID], shown: Set<ID>) -> ID? {
        let live = Set(surviving)
        guard let selected else { return surviving.first(where: shown.contains) ?? surviving.first }
        if live.contains(selected) { return selected }
        let visible = { (id: ID) in live.contains(id) && shown.contains(id) }
        return neighbor(of: selected, in: old, preferNext: true, where: visible)
            ?? surviving.first(where: shown.contains)
            ?? neighbor(of: selected, in: old, preferNext: true, where: live.contains)
            ?? surviving.first
    }

    // MARK: Workspaces

    /// The workspace a window shows after `shown` left it: the next one
    /// below in the sidebar's visual order, else the one above. `old` is
    /// the visual order before, `surviving` the workspaces the window
    /// still lists.
    public static func workspace<ID: Hashable>(shown: ID?, old: [ID], surviving: [ID]) -> ID? {
        let live = Set(surviving)
        guard let shown else { return surviving.first }
        if live.contains(shown) { return shown }
        return neighbor(of: shown, in: old, preferNext: true, where: live.contains) ?? surviving.first
    }
}
