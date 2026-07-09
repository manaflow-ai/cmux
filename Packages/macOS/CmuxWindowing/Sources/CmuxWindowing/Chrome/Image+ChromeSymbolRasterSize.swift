import SwiftUI

extension Image {
    /// Keeps a positive symbol frame while avoiding the blank-prone resizable
    /// SF Symbol rasterizer. Lifted from the app target's `cmuxSymbolRasterSize`
    /// with the raster-point-size clamp inlined (positive, NaN-guarded) so the
    /// window-chrome icon style carries no dependency on the app-target symbol
    /// namespace.
    ///
    /// Intentionally `internal`: it is consumed only by ``HeaderChromeIconStyle``
    /// inside this package. Keeping it non-public prevents an ambiguity with the
    /// app target's identically-named `Image.cmuxSymbolRasterSize` in files that
    /// import both modules.
    func cmuxSymbolRasterSize(
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
