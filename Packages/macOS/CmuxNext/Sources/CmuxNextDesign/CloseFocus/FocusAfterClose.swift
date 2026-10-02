/// The focus successor rules for every close kind (plans/cmux-next/close-focus.md).
/// One pure function per kind; the App's focus reducer, tab selection and
/// window selection call these and nothing else decides a successor.
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

    /// The pane to focus after `focused` closed. `before` holds the columns
    /// of the screen that showed it, in visual order (left sticky, strip,
    /// right sticky; a split screen is one column), each its panes in layout
    /// order. `after[i]` holds the panes of that same column (by column
    /// identity) after the change, empty when the column is gone; a pane
    /// that moved to another column is not in `after[i]` although it is
    /// alive. `history` is this window's focus history for the workspace,
    /// newest first. Returns `focused` when it survives.
    ///
    /// previousNeighbor: the previous pane of its column that is still in
    /// that column, else the next one; else any pane now in the column
    /// (most recently focused first); when the column is empty or gone,
    /// the nearest non-empty column to the left, else to the right (the
    /// sticky column's left neighbor is the strip's last column), entering
    /// that column at its most recently focused pane, else its first.
    /// mostRecent: the newest pane of `history` that is in `after`, else
    /// previousNeighbor.
    public static func pane<ID: Hashable>(focused: ID?, before: [[ID]], after: [[ID]], history: [ID],
                                          policy: CloseFocusPolicy) -> ID? {
        let surviving = Set(after.flatMap { $0 })
        guard let focused else { return firstPane(after, history: history) }
        if surviving.contains(focused) { return focused }
        if policy == .mostRecent, let recent = history.first(where: { $0 != focused && surviving.contains($0) }) {
            return recent
        }
        guard let column = before.firstIndex(where: { $0.contains(focused) }), after.indices.contains(column) else {
            return firstPane(after, history: history)
        }
        let stayed = Set(after[column])
        if let inColumn = neighbor(of: focused, in: before[column], preferNext: false, where: stayed.contains) {
            return inColumn
        }
        if let added = history.first(where: stayed.contains) ?? after[column].first { return added }
        // The column is empty or gone: the nearest non-empty column to the
        // left, else to the right.
        let alive = { (index: Int) in after.indices.contains(index) && !after[index].isEmpty }
        let left = before[..<column].indices.last(where: alive)
        let right = before[(column + 1)...].indices.first(where: alive)
        guard let next = left ?? right else { return firstPane(after, history: history) }
        return history.first(where: after[next].contains) ?? after[next].first
    }

    private static func firstPane<ID: Hashable>(_ columns: [[ID]], history: [ID]) -> ID? {
        let all = columns.flatMap { $0 }
        return history.first(where: all.contains) ?? all.first
    }

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
