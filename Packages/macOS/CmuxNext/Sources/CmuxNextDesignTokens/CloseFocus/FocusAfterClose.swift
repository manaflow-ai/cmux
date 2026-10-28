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
    ///
    /// `opener` maps a link tab to the tab that opened it (live relations
    /// only, among `old`). A closed tab in that tree goes back to its
    /// family first, in Chrome's order (`DetermineNewSelectedIndex`): its
    /// next child, else a sibling (the next tab with its opener), else its
    /// opener. Only shown, surviving tabs count. Tabs without relations
    /// (terminals, agents, a browser tab after an unrelated switch) keep
    /// next-else-previous.
    public static func tab<ID: Hashable>(selected: ID?, old: [ID], surviving: [ID], shown: Set<ID>,
                                         opener: [ID: ID] = [:]) -> ID? {
        let live = Set(surviving)
        guard let selected else { return surviving.first(where: shown.contains) ?? surviving.first }
        if live.contains(selected) { return selected }
        let visible = { (id: ID) in live.contains(id) && shown.contains(id) }
        if let family = openerFamily(of: selected, in: old, opener: opener, where: visible) { return family }
        return neighbor(of: selected, in: old, preferNext: true, where: visible)
            ?? surviving.first(where: shown.contains)
            ?? neighbor(of: selected, in: old, preferNext: true, where: live.contains)
            ?? surviving.first
    }

    /// Chrome's opener step for a closed tab: the next child of `closed`,
    /// else the next tab with the same opener, else the opener. "Next" is
    /// Chrome's `GetIndexOfNextWebContentsOpenedBy`: the nearest after
    /// `closed`, else the nearest before it. nil when none qualifies.
    package static func openerFamily<ID: Hashable>(of closed: ID, in old: [ID], opener: [ID: ID],
                                           where qualifies: (ID) -> Bool) -> ID? {
        guard !opener.isEmpty, let index = old.firstIndex(of: closed) else { return nil }
        func openedBy(_ parent: ID) -> ID? {
            old[(index + 1)...].first { opener[$0] == parent && qualifies($0) }
                ?? old[..<index].last { opener[$0] == parent && qualifies($0) }
        }
        if let child = openedBy(closed) { return child }
        guard let parent = opener[closed] else { return nil }
        if let sibling = openedBy(parent) { return sibling }
        return qualifies(parent) ? parent : nil
    }

    /// The opener relations among `order`, from `opener` (child to opener,
    /// possibly naming tabs that are gone). A tab whose opener is not in
    /// `order` takes that opener's own opener, as Chrome's `FixOpeners`
    /// does when a tab leaves the strip; a relation back to the tab
    /// itself is dropped. Only tabs in `order` are keys.
    public static func liveOpeners<ID: Hashable>(_ opener: [ID: ID], among order: [ID]) -> [ID: ID] {
        let present = Set(order)
        var result: [ID: ID] = [:]
        for tab in order {
            var seen: Set<ID> = [tab]
            var parent = opener[tab]
            while let current = parent, !present.contains(current), seen.insert(current).inserted {
                parent = opener[current]
            }
            if let parent, present.contains(parent), parent != tab { result[tab] = parent }
        }
        return result
    }

    // MARK: Workspaces

    /// The workspace a window shows after `shown` left it: the next one
    /// below in the sidebar's visual order, else the one above. `old` is
    /// the order before (a window's members, in the order they joined it,
    /// or the sidebar model's), `surviving` the workspaces the window still
    /// lists. `orders`, the sidebar's row orders before the close, most
    /// preferred first (the rows as drawn, then the model's rows), are
    /// tried in turn: the first that lists `shown` and has a surviving
    /// neighbor among `old` picks it. So a drawn row hands off to a drawn
    /// row (folder sorting and a filter apply; a collapsed group's members
    /// only when no drawn row is left), and a list row never to a
    /// workspace no row lists (a pinned tile) while a row is left. `old`
    /// decides last.
    public static func workspace<ID: Hashable>(shown: ID?, old: [ID], surviving: [ID], orders: [[ID]] = []) -> ID? {
        let live = Set(surviving)
        guard let shown else { return surviving.first }
        if live.contains(shown) { return shown }
        let members = Set(old)
        for order in orders where order.contains(shown) {
            let rows = order.filter { $0 == shown || members.contains($0) }
            if let next = neighbor(of: shown, in: rows, preferNext: true, where: live.contains) { return next }
        }
        return neighbor(of: shown, in: old, preferNext: true, where: live.contains) ?? surviving.first
    }
}
