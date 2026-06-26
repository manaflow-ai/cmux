public import CoreGraphics

/// Immutable snapshot of the geometry the titlebar controls accessory last
/// applied: the content size, container height, and leading/vertical offsets.
/// Compared against the next computed layout (see
/// ``TitlebarControlsSizingPolicy/shouldApplyLayout(previous:next:tolerance:)``)
/// to skip redundant frame updates.
public struct TitlebarControlsLayoutSnapshot: Equatable {
    /// Size of the hosted controls content.
    public let contentSize: CGSize
    /// Height of the accessory container, including titlebar padding.
    public let containerHeight: CGFloat
    /// Leading horizontal offset applied to the content.
    public let xOffset: CGFloat
    /// Vertical offset applied to the content.
    public let yOffset: CGFloat

    /// Creates a layout snapshot from the resolved geometry values.
    public init(
        contentSize: CGSize,
        containerHeight: CGFloat,
        xOffset: CGFloat,
        yOffset: CGFloat
    ) {
        self.contentSize = contentSize
        self.containerHeight = containerHeight
        self.xOffset = xOffset
        self.yOffset = yOffset
    }
}
