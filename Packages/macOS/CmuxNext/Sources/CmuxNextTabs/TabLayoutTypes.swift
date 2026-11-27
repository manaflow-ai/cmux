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

    public init(
        id: TabID,
        isPinned: Bool = false,
        isSelected: Bool = false,
        groupID: TabGroupID? = nil,
        fixedWidth: CGFloat? = nil,
        isCollapsed: Bool = false,
        isGroupChip: Bool = false
    ) {
        self.id = id
        self.isPinned = isPinned
        self.isSelected = isSelected
        self.groupID = groupID
        self.fixedWidth = fixedWidth
        self.isCollapsed = isCollapsed
        self.isGroupChip = isGroupChip
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
    /// It shares the row's width with the other flexible tabs (``TabRowShare``): unpinned, not collapsed, not content-sized.
    public var isFlexible = false

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
    /// How the flexible tabs shared the row: the one input of the slots that depends on ``availableWidth``
    /// (``TabLayoutEngine/resized(_:availableWidth:style:metrics:closingModeWidth:)``).
    public var share: TabRowShare
    /// The flexible tabs (unpinned, not content-sized, not collapsed) that shared the row.
    public var flexibleCount: Int
    /// The row's width the flexible tabs did not share: the pinned tabs, their gap and the content-sized items.
    public var reservedWidth: CGFloat

    public init(slots: [TabLayoutSlot], contentWidth: CGFloat, standardWidth: CGFloat, availableWidth: CGFloat, share: TabRowShare = .none,
                flexibleCount: Int = 0, reservedWidth: CGFloat = 0) {
        self.slots = slots
        self.contentWidth = contentWidth
        self.standardWidth = standardWidth
        self.availableWidth = availableWidth
        self.share = share
        self.flexibleCount = flexibleCount
        self.reservedWidth = reservedWidth
    }

    public var isOverflowing: Bool { contentWidth > availableWidth + 0.5 }

    public func slot(_ id: TabID) -> TabLayoutSlot? {
        slots.first { $0.id == id }
    }
}

/// How the flexible tabs of a row share its width (``TabLayoutEngine``). Their widths follow from it alone, so a strip
/// whose width changes keeps every slot while the share stays the same.
public enum TabRowShare: Equatable, Sendable {
    /// No flexible tab.
    case none
    /// Every flexible tab this wide: compact tabs, tabs at their widest, or at their narrowest (the strip scrolls).
    case each(CGFloat)
    /// One flexible tab, narrower than its widest.
    case alone(CGFloat)
    /// The row split in whole points: each tab `base` wide, the first `extra` one point wider.
    case split(base: CGFloat, extra: Int)
    /// Full Width Tab mode: the tab spans this width.
    case fullWidth(CGFloat)

    /// The width of the flexible tab at `index` (leading first).
    func width(at index: Int) -> CGFloat {
        switch self {
        case .none: 0
        case .each(let width), .alone(let width), .fullWidth(let width): width
        case .split(let base, let extra): index < extra ? base + 1 : base
        }
    }

    /// The width of an inactive flexible tab (the last one's): 0 with none.
    func standardWidth(count: Int) -> CGFloat {
        switch self {
        case .none: 0
        default: width(at: count - 1)
        }
    }
}

extension [TabLayoutItem] {
    /// Inserts a drop gap before the `tabIndex`-th tab. The gap goes before
    /// that tab's chip unless it joins that tab's group.
    mutating func insertPlaceholder(_ placeholder: TabLayoutItem, atTabIndex tabIndex: Int) {
        var seen = 0
        var position = count
        for (offset, item) in enumerated() where !item.isGroupChip {
            if seen == tabIndex {
                position = offset
                break
            }
            seen += 1
        }
        if position > 0, self[position - 1].isGroupChip, self[position - 1].groupID != placeholder.groupID {
            position -= 1
        }
        insert(placeholder, at: position)
    }
}
