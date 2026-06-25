public import SwiftUI

extension Image {
    /// Keeps a positive symbol frame while avoiding the blank-prone resizable
    /// SF Symbol rasterizer.
    ///
    /// Lifted from the app target's `cmuxSymbolRasterSize` with the
    /// raster-point-size clamp inlined (positive, NaN-guarded) so UI packages can
    /// reuse one shared helper instead of each re-declaring the same extension.
    /// - Parameters:
    ///   - pointSize: Requested symbol point size; clamped to at least `1` and
    ///     coerced to `1` when non-finite.
    ///   - weight: Optional font weight applied to the symbol glyph.
    ///   - alignment: Frame alignment for the rasterized glyph.
    /// - Returns: The image rendered at a system font of the clamped size inside a
    ///   square frame of that size.
    public func cmuxSymbolRasterSize(
        _ pointSize: CGFloat,
        weight: Font.Weight? = nil,
        alignment: Alignment = .center
    ) -> some View {
        let rasterSize: CGFloat = pointSize.isFinite ? max(1, pointSize) : 1
        let systemFont: Font = weight.map { .system(size: rasterSize, weight: $0) } ?? .system(size: rasterSize)
        return font(systemFont)
            .frame(width: rasterSize, height: rasterSize, alignment: alignment)
    }
}
