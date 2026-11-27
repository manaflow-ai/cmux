/// Chrome's tab multi-selection for one strip (`ui::ListSelectionModel`, Leo 2026-10-19: "we need
/// to be able to multi select those tabs"). Cmd-click adds a tab or takes it out, Shift-click
/// selects the range from the anchor to the clicked tab, and a plain click or Esc goes back to the
/// one active tab. The active tab (`TabStripModel.selectedID`) is always one of the selected tabs;
/// `ids` is empty while only the active tab is selected, which is the usual state.
public struct TabMultiSelection: Hashable, Sendable {
    /// Every selected tab, the active one included. Never a single tab: empty instead.
    public private(set) var ids: Set<TabID> = []
    /// Where a Shift-click range starts: the last tab clicked without Shift (Chrome's anchor). Nil
    /// reads as the active tab.
    public private(set) var anchor: TabID?

    public init() {}

    /// The click's kind, from its modifiers.
    public enum Click: Hashable, Sendable {
        /// No modifier: the clicked tab alone.
        case plain
        /// Cmd: the clicked tab joins the selection or leaves it.
        case toggle
        /// Shift: the range from the anchor to the clicked tab, instead of the selection.
        case range
        /// Cmd-Shift: the range from the anchor to the clicked tab, added to the selection.
        case addRange
    }

    /// More than one tab is selected.
    public var isMultiple: Bool { ids.count > 1 }

    public func contains(_ id: TabID) -> Bool { ids.contains(id) }

    /// The selected tabs in `order` (the strip's display order): the active tab alone while only it
    /// is selected.
    public func ordered(in order: [TabID], active: TabID?) -> [TabID] {
        guard isMultiple else { return active.map { [$0] } ?? [] }
        return order.filter(ids.contains)
    }

    /// Applies a click on `id` in `order` (display order) while `active` is the active tab. Returns
    /// the tab to make active, nil to leave the active tab as it is.
    public mutating func click(_ id: TabID, _ click: Click, order: [TabID], active: TabID?) -> TabID? {
        let current = isMultiple ? ids : Set(active.map { [$0] } ?? [])
        switch click {
        case .plain:
            ids = []
            anchor = id
            return id
        case .toggle:
            anchor = id
            guard current.contains(id) else {
                set(current.union([id]))
                return id
            }
            // The last selected tab stays selected (Chrome).
            guard current.count > 1 else { return nil }
            let rest = current.subtracting([id])
            set(rest)
            guard id == active else { return nil }
            // The active tab left: the nearest selected tab after it becomes active, else the one before.
            let index = order.firstIndex(of: id) ?? order.count
            let next = order[min(index + 1, order.count)...].first(where: rest.contains) ?? order[..<min(index, order.count)].last(where: rest.contains)
            anchor = next
            return next
        case .range, .addRange:
            let start = anchor.flatMap { order.contains($0) ? $0 : nil } ?? active ?? id
            guard let a = order.firstIndex(of: start), let b = order.firstIndex(of: id) else { return nil }
            let range = Set(order[min(a, b)...max(a, b)])
            set(click == .range ? range : current.union(range))
            anchor = start
            return id
        }
    }

    /// Back to the active tab alone.
    public mutating func clear() {
        ids = []
    }

    /// Tabs that left the strip leave the selection; fewer than two left is no selection.
    public mutating func follow(order: [TabID]) {
        guard !ids.isEmpty || anchor != nil else { return }
        let present = Set(order)
        if let anchor, !present.contains(anchor) { self.anchor = nil }
        set(ids.intersection(present))
    }

    /// The active tab changed (a click, a shortcut, the CLI, a close): a tab outside the selection
    /// ends it, as in Chrome; a selected tab keeps it.
    public mutating func activated(_ id: TabID?) {
        if let id, ids.contains(id) { return }
        ids = []
    }

    private mutating func set(_ selection: Set<TabID>) {
        ids = selection.count > 1 ? selection : []
    }
}

/// Chrome's `TabStripModel::MoveSelectedTabsTo`: the order after moving `selection` to `index`,
/// where `index` counts the strip's tabs without the selected ones. The selected tabs keep their
/// order and stay in their section: pinned ones go to `index` among the pinned tabs (the end of
/// them when `index` is past them), unpinned ones to `index` among the unpinned tabs (their start
/// when `index` is among the pinned tabs).
public struct TabSelectionMove: Hashable, Sendable {
    /// Display order, pinned tabs first.
    public var order: [TabID]
    public var pinned: Set<TabID>

    public init(order: [TabID], pinned: Set<TabID>) {
        self.order = order
        self.pinned = pinned
    }

    public init(_ tabs: [TabItem]) {
        self.init(order: tabs.map(\.id), pinned: Set(tabs.filter(\.isPinned).map(\.id)))
    }

    public func moving(_ selection: Set<TabID>, to index: Int) -> [TabID] {
        let rest = order.filter { !selection.contains($0) }
        let restPinned = rest.filter(pinned.contains), restUnpinned = rest.filter { !pinned.contains($0) }
        let movedPinned = order.filter { selection.contains($0) && pinned.contains($0) }
        let movedUnpinned = order.filter { selection.contains($0) && !pinned.contains($0) }
        let pinnedAt = min(max(index, 0), restPinned.count)
        let unpinnedAt = min(max(index - restPinned.count, 0), restUnpinned.count)
        var result = Array(restPinned[..<pinnedAt])
        result += movedPinned
        result += restPinned[pinnedAt...]
        result += restUnpinned[..<unpinnedAt]
        result += movedUnpinned
        result += restUnpinned[unpinnedAt...]
        return result
    }

    /// The next one-tab move (the tab and its final display index) that brings `current` closer to
    /// `target`, nil once they agree. The App moves a multi-tab drop one tab at a time (the daemon
    /// moves one tab per command), reading the order each move left. Tabs only one side has are left out.
    public static func nextStep(from current: [TabID], toward target: [TabID]) -> (id: TabID, index: Int)? {
        let shared = Set(current).intersection(target)
        let now = current.filter(shared.contains), goal = target.filter(shared.contains)
        guard let index = now.indices.first(where: { now[$0] != goal[$0] }) else { return nil }
        // Its index in `current`, which can hold tabs `target` does not.
        let id = goal[index]
        let before = index > 0 ? now[index - 1] : nil
        let position = before.flatMap { current.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let from = current.firstIndex(of: id) ?? 0
        return (id, from < position ? position - 1 : position)
    }
}
