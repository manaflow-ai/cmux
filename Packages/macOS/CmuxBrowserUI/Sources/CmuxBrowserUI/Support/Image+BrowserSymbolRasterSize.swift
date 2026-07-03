import SwiftUI

extension Image {
    /// Keeps a positive symbol frame while avoiding the blank-prone resizable
    /// SF Symbol rasterizer. Lifted from the app target's `cmuxSymbolRasterSize`
    /// with the raster-point-size clamp inlined (positive, NaN-guarded) so the
    /// browser top-chrome views moved into this package carry no dependency on
    /// the app-target symbol namespace.
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
