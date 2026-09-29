public import CoreGraphics

/// One tab as layout sees it.
public struct TabLayoutItem: Equatable, Sendable {
    public var id: TabID
    public var isPinned: Bool
    public var isSelected: Bool

    public init(id: TabID, isPinned: Bool = false, isSelected: Bool = false) {
        self.id = id
        self.isPinned = isPinned
        self.isSelected = isSelected
    }
}

/// A laid out tab, in content coordinates (0 is the leading edge of the first tab).
public struct TabLayoutSlot: Equatable, Sendable {
    public var id: TabID
    public var x: CGFloat
    public var width: CGFloat
    public var isPinned: Bool

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
