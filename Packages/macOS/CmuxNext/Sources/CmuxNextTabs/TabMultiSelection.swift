import Foundation

/// Chrome's tab multi-selection for one strip (`ui::ListSelectionModel`, Leo 2026-10-19: "we need
/// to be able to multi select those tabs"). Cmd-click adds a tab or takes it out, Shift-click
/// selects the range from the anchor to the clicked tab, and a plain click or Esc goes back to the
/// one active tab. The active tab (`TabStripModel.selectedID`) is always one of the selected tabs;
/// `ids` is empty while only the active tab is selected, which is the usual state.
///
/// The rules are cmux-window-rules' (`tabs::selection`, op `tab_selection` of the app FFI's JSON
/// channel); `TabSelectionVectorTests` checks them against the vectors the Swift rules wrote
/// before they moved.
public struct TabMultiSelection: Hashable, Sendable {
    /// Every selected tab, the active one included. Never a single tab: empty instead.
    public private(set) var ids: Set<TabID> = []
    /// Where a Shift-click range starts: the last tab clicked without Shift (Chrome's anchor). Nil
    /// reads as the active tab.
    public private(set) var anchor: TabID?

    public init() {}

    /// The click's kind, from its modifiers.
    public enum Click: String, Hashable, Sendable {
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
        change(.click(id: id.rawValue, click: click.rawValue, order: order.map(\.rawValue), active: active?.rawValue))
    }

    /// Back to the active tab alone.
    public mutating func clear() {
        ids = []
    }

    /// Tabs that left the strip leave the selection; fewer than two left is no selection.
    public mutating func follow(order: [TabID]) {
        guard !ids.isEmpty || anchor != nil else { return }
        change(.follow(order: order.map(\.rawValue)))
    }

    /// The active tab changed (a click, a shortcut, the CLI, a close): a tab outside the selection
    /// ends it, as in Chrome; a selected tab keeps it.
    public mutating func activated(_ id: TabID?) {
        guard !ids.isEmpty else { return }
        change(.activated(id: id?.rawValue))
    }

    /// Sends the selection and `change` to the rule and takes the selection it answers; the tab a
    /// click makes active. A refused call leaves the selection as it was.
    @discardableResult
    private mutating func change(_ change: Change) -> TabID? {
        let request = ChangeRequest(selection: Wire(ids: ids.map(\.rawValue).sorted(), anchor: anchor?.rawValue), change: change)
        guard let reply: ChangeReply = TabRules.call("tab_selection", request) else { return nil }
        ids = Set(reply.selection.ids.map { TabID($0) })
        anchor = reply.selection.anchor.map { TabID($0) }
        return reply.active.map { TabID($0) }
    }

    private nonisolated struct Wire: Codable {
        var ids: [String]
        var anchor: String?
    }

    /// Encodes as the rule reads it: `{"click": {"id": …, "click": …, "order": […], "active": …}}`.
    private nonisolated enum Change: Encodable {
        case click(id: String, click: String, order: [String], active: String?)
        case follow(order: [String])
        case activated(id: String?)
    }

    private nonisolated struct ChangeRequest: Encodable {
        var selection: Wire
        var change: Change
    }

    private nonisolated struct ChangeReply: Decodable {
        var selection: Wire
        var active: String?
    }
}

/// Chrome's `TabStripModel::MoveSelectedTabsTo`: the order after moving `selection` to `index`,
/// where `index` counts the strip's tabs without the selected ones. The selected tabs keep their
/// order and stay in their section: pinned ones go to `index` among the pinned tabs (the end of
/// them when `index` is past them), unpinned ones to `index` among the unpinned tabs (their start
/// when `index` is among the pinned tabs). The rule is cmux-window-rules' (`tab_selection_move`).
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
        nonisolated struct Request: Encodable { var order: [String], pinned: [String], selection: [String], index: Int }
        nonisolated struct Reply: Decodable { var order: [String] }
        let request = Request(order: order.map(\.rawValue), pinned: pinned.map(\.rawValue).sorted(),
                              selection: selection.map(\.rawValue).sorted(), index: index)
        guard let reply: Reply = TabRules.call("tab_selection_move", request) else { return order }
        return reply.order.map { TabID($0) }
    }

    /// The next one-tab move (the tab and its final display index) that brings `current` closer to
    /// `target`, nil once they agree. The App moves a multi-tab drop one tab at a time (the daemon
    /// moves one tab per command), reading the order each move left. Tabs only one side has are left
    /// out. The rule is cmux-window-rules' (`tab_selection_next_step`).
    public static func nextStep(from current: [TabID], toward target: [TabID]) -> (id: TabID, index: Int)? {
        nonisolated struct Request: Encodable { var current: [String], target: [String] }
        nonisolated struct Step: Decodable { var id: String, index: Int }
        nonisolated struct Reply: Decodable { var step: Step? }
        let request = Request(current: current.map(\.rawValue), target: target.map(\.rawValue))
        guard let step = (TabRules.call("tab_selection_next_step", request) as Reply?)?.step else { return nil }
        return (TabID(step.id), step.index)
    }
}
