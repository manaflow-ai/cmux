public import CoreGraphics

/// Icon sizes relative to the text beside them.
public nonisolated extension CGFloat {
    /// The smallest size an icon draws at; smaller requests clamp to it.
    static let iconFloor: CGFloat = 12

    /// The size an `Icon` takes when the caller gives none (a 13 pt row).
    static let iconDefaultSize: CGFloat = 16

    /// Below this size, icons whose catalog entry says `denseStyle: solid`
    /// draw Solid so they stay legible.
    static let iconDenseThreshold: CGFloat = 13

    /// The icon size for a row whose label is `pointSize` points.
    static func iconRowSize(forLabelPointSize pointSize: CGFloat) -> CGFloat {
        Swift.max(iconFloor, (1.2 * pointSize).rounded())
    }
}
