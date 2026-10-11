import Foundation
public import Observation

/// One tab group in a pane strip.
@Observable @MainActor
public final class TabGroupModel: Identifiable {
    public let id: TabGroupID
    public internal(set) var name: String
    public internal(set) var color: String?
    public internal(set) var collapsed: Bool
    public internal(set) var members: [TabGroupMember]
    /// Linked saved record (`saved-tab-groups-v1`).
    public internal(set) var savedID: SavedTabGroupID?

    init(_ s: TabGroupSnapshot) {
        id = s.id
        name = s.name
        color = s.color
        collapsed = s.collapsed
        members = s.tabs
        savedID = s.savedID
    }

    func update(_ s: TabGroupSnapshot) {
        if name != s.name { name = s.name }
        if color != s.color { color = s.color }
        if collapsed != s.collapsed { collapsed = s.collapsed }
        if members != s.tabs { members = s.tabs }
        if savedID != s.savedID { savedID = s.savedID }
    }

    func setCollapsed(_ value: Bool) {
        if collapsed != value { collapsed = value }
    }
}

/// Contiguous run of a group's tabs in a strip, cached on the pane.
public struct TabGroupSpan: Sendable, Hashable {
    public let group: TabGroupID
    public let range: Range<Int>
}

/// One saved tab group record (session-wide).
@Observable @MainActor
public final class SavedTabGroupModel: Identifiable {
    public let id: SavedTabGroupID
    public internal(set) var name: String
    public internal(set) var color: String?
    public internal(set) var tabs: [SavedTab]
    public internal(set) var openGroup: TabGroupID?

    init(_ s: SavedTabGroupSnapshot) {
        id = s.id
        name = s.name
        color = s.color
        tabs = s.tabs
        openGroup = s.openGroup
    }

    func update(_ s: SavedTabGroupSnapshot) {
        if name != s.name { name = s.name }
        if color != s.color { color = s.color }
        if tabs != s.tabs { tabs = s.tabs }
        if openGroup != s.openGroup { openGroup = s.openGroup }
    }
}
