public import CoreGraphics
public import Foundation
public import Observation

/// Visual mode of a strip.
public enum TabStripStyle: Hashable, Sendable {
    /// Tab sizing: tabs shrink evenly between a max and min width, then scroll.
    case chrome
    /// Bonsplit-like: every tab has the same fixed width, overflow scrolls.
    case compact
}

/// Input of one tab strip. The App mirrors daemon state into `tabs` and
/// `selectedID`, and handles `TabStripIntent`s from `intentHandler`.
@Observable
public final class TabStripModel {
    /// Identifies this strip in cross-strip drags.
    public let stripID: UUID
    public var tabs: [TabItem]
    /// Groups of this strip. Members reference them through `TabItem.groupID`.
    public var groups: [TabGroupItem]
    public var selectedID: TabID?
    public var style: TabStripStyle
    public var showsNewTabButton: Bool
    /// Buttons pinned to the strip's trailing edge, in order. Empty hides
    /// the group.
    public var trailingButtons: [TabStripButton]

    /// Receives every intent. Set by the App (or the demo).
    @ObservationIgnored public var intentHandler: ((TabStripIntent) -> Void)?

    public init(
        stripID: UUID = UUID(),
        tabs: [TabItem] = [],
        groups: [TabGroupItem] = [],
        selectedID: TabID? = nil,
        style: TabStripStyle = .chrome,
        showsNewTabButton: Bool = true,
        trailingButtons: [TabStripButton] = []
    ) {
        self.stripID = stripID
        self.tabs = tabs
        self.groups = groups
        self.selectedID = selectedID
        self.style = style
        self.showsNewTabButton = showsNewTabButton
        self.trailingButtons = trailingButtons
    }

    /// Display order: pinned tabs first, then unpinned tabs in `tabs` order
    /// with each group's members gathered at its first member. `groupID` is
    /// cleared on pinned tabs and on tabs whose group is unknown.
    public var orderedTabs: [TabItem] {
        TabGroupOrdering.normalized(tabs, groups: Set(groups.map(\.id)))
    }

    public func tab(_ id: TabID) -> TabItem? {
        tabs.first { $0.id == id }
    }

    public func group(_ id: TabGroupID) -> TabGroupItem? {
        groups.first { $0.id == id }
    }

    /// Members of `group` in display order.
    public func members(of group: TabGroupID) -> [TabItem] {
        orderedTabs.filter { $0.groupID == group }
    }

    public func send(_ intent: TabStripIntent) {
        intentHandler?(intent)
    }

    static func pinnedFirst(_ tabs: [TabItem]) -> [TabItem] {
        tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
    }

    /// Closing the selected tab selects its right neighbor,
    /// or the left one when it was last. Returns the current selection when
    /// the closed tab was not selected.
    public static func selectionAfterClosing(_ closed: TabID, in ordered: [TabID], selected: TabID?) -> TabID? {
        guard selected == closed else { return selected }
        guard let index = ordered.firstIndex(of: closed) else { return selected }
        if index + 1 < ordered.count { return ordered[index + 1] }
        if index > 0 { return ordered[index - 1] }
        return nil
    }
}
