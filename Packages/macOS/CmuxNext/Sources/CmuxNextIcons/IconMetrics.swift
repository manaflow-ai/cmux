public import CoreGraphics

/// Icon sizes relative to the text beside them.
public nonisolated enum IconMetrics {
    /// The smallest size an icon draws at; smaller requests clamp to it.
    public static let floor: CGFloat = 12

    /// The size an `Icon` takes when the caller gives none (a 13 pt row).
    public static let defaultSize: CGFloat = 16

    /// Below this size, icons whose catalog entry says `denseStyle: solid`
    /// draw Solid so they stay legible.
    public static let denseThreshold: CGFloat = 13

    /// The icon size for a row whose label is `pointSize` points.
    public static func rowSize(forLabelPointSize pointSize: CGFloat) -> CGFloat {
        max(Self.floor, (1.2 * pointSize).rounded())
    }
}
