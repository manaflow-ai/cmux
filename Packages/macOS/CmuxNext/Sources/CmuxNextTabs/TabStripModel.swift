public import CoreGraphics
public import Foundation
public import Observation

/// Visual mode of a strip.
public enum TabStripStyle: Hashable, Sendable {
    /// Chrome sizing: tabs shrink evenly between a max and min width, then scroll.
    case chrome
    /// Bonsplit-like: every tab has the same fixed width, overflow scrolls.
    case compact
}

/// What caused a close. `mouse` and `middleClick` enter Chrome's closing mode,
/// which keeps tab widths frozen until the pointer leaves the strip.
public enum TabCloseSource: Hashable, Sendable {
    case mouse
    case middleClick
    case keyboard
    case contextMenu
    case accessibility

    var entersClosingMode: Bool { self == .mouse || self == .middleClick }
}

public enum TabSplitDirection: Hashable, Sendable {
    case right
    case down
}

/// Everything the strip asks the App to do. The strip never mutates layout
/// or daemon state itself; the App applies an intent and updates the model.
/// Indices are positions in `TabStripModel.orderedTabs` (pinned first).
public enum TabStripIntent: Equatable, Sendable {
    case select(TabID)
    case close(TabID, source: TabCloseSource)
    case closeOthers(keeping: TabID)
    case closeToRight(of: TabID)
    /// Drag reorder inside one strip. `to` is the final index of the tab.
    case reorder(TabID, from: Int, to: Int)
    /// `after` is nil for the new-tab button and empty-space double-click (append).
    case newTab(after: TabID?)
    case pin(TabID)
    case unpin(TabID)
    case rename(TabID)
    case duplicate(TabID)
    case moveToNewSplit(TabID, TabSplitDirection)
    case moveToNewColumn(TabID)
    /// A tab was dragged out of the strip. The App's drag session takes over
    /// pointer tracking; the strip keeps the slot collapsed until the model
    /// drops the tab or the App calls `TabStripView.restoreDetachedTab`.
    case dragBegan(TabDragStart)
}

/// Input of one tab strip. The App mirrors daemon state into `tabs` and
/// `selectedID`, and handles `TabStripIntent`s from `intentHandler`.
@Observable
public final class TabStripModel {
    /// Identifies this strip in cross-strip drags.
    public let stripID: UUID
    public var tabs: [TabItem]
    public var selectedID: TabID?
    public var style: TabStripStyle
    public var showsNewTabButton: Bool

    /// Receives every intent. Set by the App (or the demo).
    @ObservationIgnored public var intentHandler: ((TabStripIntent) -> Void)?

    public init(
        stripID: UUID = UUID(),
        tabs: [TabItem] = [],
        selectedID: TabID? = nil,
        style: TabStripStyle = .chrome,
        showsNewTabButton: Bool = true
    ) {
        self.stripID = stripID
        self.tabs = tabs
        self.selectedID = selectedID
        self.style = style
        self.showsNewTabButton = showsNewTabButton
    }

    /// Display order: pinned tabs first, each group in `tabs` order.
    public var orderedTabs: [TabItem] {
        Self.pinnedFirst(tabs)
    }

    public func tab(_ id: TabID) -> TabItem? {
        tabs.first { $0.id == id }
    }

    public func send(_ intent: TabStripIntent) {
        intentHandler?(intent)
    }

    static func pinnedFirst(_ tabs: [TabItem]) -> [TabItem] {
        tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
    }

    /// Chrome's rule: closing the selected tab selects its right neighbor,
    /// or the left one when it was last. Returns the current selection when
    /// the closed tab was not selected.
    public static func selectionAfterClosing(_ closed: TabID, in ordered: [TabID], selected: TabID?) -> TabID? {
        guard selected == closed else { return selected }
        guard let index = ordered.firstIndex(of: closed) else { return selected }
        if index + 1 < ordered.count { return ordered[index + 1] }
        if index > 0 { return ordered[index - 1] }
        return nil
    }

    // MARK: - Local reducer

    /// Applies an intent to this model directly. The demo uses it as its
    /// whole backend; the App can use it for optimistic updates before the
    /// daemon confirms. Returns false for intents that need the App
    /// (rename, splits, columns, drags between strips).
    @discardableResult
    public func apply(_ intent: TabStripIntent, makeTab: () -> TabItem) -> Bool {
        var ordered = orderedTabs
        switch intent {
        case .select(let id):
            guard tab(id) != nil else { return false }
            selectedID = id
            return true
        case .close(let id, _):
            let next = Self.selectionAfterClosing(id, in: ordered.map(\.id), selected: selectedID)
            ordered.removeAll { $0.id == id }
            tabs = ordered
            selectedID = next
            return true
        case .closeOthers(let keep):
            tabs = ordered.filter { $0.id == keep || $0.isPinned }
            selectedID = keep
            return true
        case .closeToRight(let id):
            guard let index = ordered.firstIndex(where: { $0.id == id }) else { return false }
            let kept = Array(ordered[...index])
            tabs = kept
            if let selectedID, !kept.contains(where: { $0.id == selectedID }) {
                self.selectedID = id
            }
            return true
        case .reorder(let id, _, let to):
            guard let from = ordered.firstIndex(where: { $0.id == id }) else { return false }
            let item = ordered.remove(at: from)
            ordered.insert(item, at: min(max(to, 0), ordered.count))
            tabs = Self.pinnedFirst(ordered)
            return true
        case .newTab(let after):
            let item = makeTab()
            if let after, let index = ordered.firstIndex(where: { $0.id == after }) {
                ordered.insert(item, at: index + 1)
            } else {
                ordered.append(item)
            }
            tabs = Self.pinnedFirst(ordered)
            selectedID = item.id
            return true
        case .duplicate(let id):
            guard let index = ordered.firstIndex(where: { $0.id == id }) else { return false }
            var copy = makeTab()
            let source = ordered[index]
            copy.title = source.title
            copy.subtitle = source.subtitle
            copy.icon = source.icon
            copy.isPinned = source.isPinned
            ordered.insert(copy, at: index + 1)
            tabs = Self.pinnedFirst(ordered)
            selectedID = copy.id
            return true
        case .pin(let id), .unpin(let id):
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
            // Rebase on display order first so the tab lands at the end of
            // the pinned group (pin) or the start of the unpinned group (unpin).
            tabs = ordered
            let reindex = tabs.firstIndex(where: { $0.id == id }) ?? index
            if case .pin = intent { tabs[reindex].isPinned = true } else { tabs[reindex].isPinned = false }
            tabs = orderedTabs
            return true
        case .rename, .moveToNewSplit, .moveToNewColumn, .dragBegan:
            return false
        }
    }
}
