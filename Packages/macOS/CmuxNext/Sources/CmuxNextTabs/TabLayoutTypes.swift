public import CoreGraphics

/// One tab as layout sees it.
public struct TabLayoutItem: Equatable, Sendable {
    public var id: TabID
    public var isPinned: Bool
    public var isSelected: Bool
    public var groupID: TabGroupID?
    /// Content-sized items (group chips, a group-sized drop gap) keep this width.
    public var fixedWidth: CGFloat?
    /// Member of a collapsed group: laid out at zero width, behind its chip.
    public var isCollapsed: Bool
    public var isGroupChip: Bool
    /// The tab's content width (icon, title and the close button's room),
    /// for `.chrome` strips that fit tabs to their titles. Nil keeps the
    /// even max-width split.
    public var naturalWidth: CGFloat?

    public init(
        id: TabID,
        isPinned: Bool = false,
        isSelected: Bool = false,
        groupID: TabGroupID? = nil,
        fixedWidth: CGFloat? = nil,
        isCollapsed: Bool = false,
        isGroupChip: Bool = false,
        naturalWidth: CGFloat? = nil
    ) {
        self.id = id
        self.isPinned = isPinned
        self.isSelected = isSelected
        self.groupID = groupID
        self.fixedWidth = fixedWidth
        self.isCollapsed = isCollapsed
        self.isGroupChip = isGroupChip
        self.naturalWidth = naturalWidth
    }
}

/// A laid out tab, in content coordinates (0 is the leading edge of the first tab).
public struct TabLayoutSlot: Equatable, Sendable {
    public var id: TabID
    public var x: CGFloat
    public var width: CGFloat
    public var isPinned: Bool
    public var groupID: TabGroupID? = nil
    public var isGroupChip = false
    public var isCollapsed = false

    public var maxX: CGFloat { x + width }
}

public struct TabLayoutResult: Equatable, Sendable {
    public var slots: [TabLayoutSlot]
    /// Total width of all tabs, including the pinned group gap.
    public var contentWidth: CGFloat
    /// Width given to an inactive unpinned tab (0 when there are none).
    public var standardWidth: CGFloat
    /// The width tabs were allowed to fill.
    public var availableWidth: CGFloat

    public var isOverflowing: Bool { contentWidth > availableWidth + 0.5 }

    public func slot(_ id: TabID) -> TabLayoutSlot? {
        slots.first { $0.id == id }
    }
}
