public import CmuxNextDesign

/// One tab group in a strip, as the App mirrors it from daemon state.
/// Members are the tabs whose `groupID` equals `id`; they are always
/// displayed contiguously, right after the group's chip.
public struct TabGroupItem: Identifiable, Hashable, Sendable {
    public var id: TabGroupID
    /// Empty shows the chip as a color dot.
    public var name: String
    /// A theme token or a custom color (cx-wqn5), as the daemon stores it.
    public var tint: GroupTint
    public var isCollapsed: Bool
    /// Saved groups also appear in the saved groups bar and outlive closing.
    public var isSaved: Bool
    /// Drawn before the name, at the tab icon size; nil draws the chip as before.
    public var icon: TabIcon?

    /// The token; grey for a custom color. Setting it picks that token.
    public var colorToken: GroupColor {
        get { tint.token }
        set { tint = .palette(newValue) }
    }

    public init(id: TabGroupID, name: String = "", colorToken: GroupColor = .grey, isCollapsed: Bool = false, isSaved: Bool = false,
                icon: TabIcon? = nil) {
        self.init(id: id, name: name, tint: .palette(colorToken), isCollapsed: isCollapsed, isSaved: isSaved, icon: icon)
    }

    public init(id: TabGroupID, name: String = "", tint: GroupTint, isCollapsed: Bool = false, isSaved: Bool = false,
                icon: TabIcon? = nil) {
        self.id = id
        self.name = name
        self.tint = tint
        self.isCollapsed = isCollapsed
        self.isSaved = isSaved
        self.icon = icon == TabIcon.none ? nil : icon
    }
}

/// A saved group as the saved groups bar shows it.
public struct SavedTabGroupItem: Identifiable, Hashable, Sendable {
    public var id: TabGroupID
    public var name: String
    /// A theme token or a custom color, as the daemon stores it.
    public var tint: GroupTint
    public var tabCount: Int
    /// The group is open in some pane (clicking focuses it instead of restoring).
    public var isOpen: Bool
    /// Drawn before the name on the saved group's chip.
    public var icon: TabIcon?

    /// The token; grey for a custom color.
    public var colorToken: GroupColor { tint.token }

    public init(id: TabGroupID, name: String, colorToken: GroupColor, tabCount: Int, isOpen: Bool = false, icon: TabIcon? = nil) {
        self.init(id: id, name: name, tint: .palette(colorToken), tabCount: tabCount, isOpen: isOpen, icon: icon)
    }

    public init(id: TabGroupID, name: String, tint: GroupTint, tabCount: Int, isOpen: Bool = false, icon: TabIcon? = nil) {
        self.id = id
        self.name = name
        self.tint = tint
        self.tabCount = tabCount
        self.isOpen = isOpen
        self.icon = icon
    }
}
