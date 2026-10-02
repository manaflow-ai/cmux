public import CmuxNextDesign

/// One tab group in a strip, as the App mirrors it from daemon state.
/// Members are the tabs whose `groupID` equals `id`; they are always
/// displayed contiguously, right after the group's chip.
public struct TabGroupItem: Identifiable, Hashable, Sendable {
    public var id: TabGroupID
    /// Empty shows the chip as a color dot.
    public var name: String
    public var colorToken: GroupColor
    public var isCollapsed: Bool
    /// Saved groups also appear in the saved groups bar and outlive closing.
    public var isSaved: Bool

    public init(id: TabGroupID, name: String = "", colorToken: GroupColor = .grey, isCollapsed: Bool = false, isSaved: Bool = false) {
        self.id = id
        self.name = name
        self.colorToken = colorToken
        self.isCollapsed = isCollapsed
        self.isSaved = isSaved
    }
}

/// A saved group as the saved groups bar shows it.
public struct SavedTabGroupItem: Identifiable, Hashable, Sendable {
    public var id: TabGroupID
    public var name: String
    public var colorToken: GroupColor
    public var tabCount: Int
    /// The group is open in some pane (clicking focuses it instead of restoring).
    public var isOpen: Bool

    public init(id: TabGroupID, name: String, colorToken: GroupColor, tabCount: Int, isOpen: Bool = false) {
        self.id = id
        self.name = name
        self.colorToken = colorToken
        self.tabCount = tabCount
        self.isOpen = isOpen
    }
}
