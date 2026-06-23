public import SwiftUI

/// A fixed-size SF Symbol glyph used inside panel header controls.
///
/// Renders the symbol with the blank-prone-resistant rasterizer
/// (``SwiftUI/Image/cmuxSymbolRasterSize(_:weight:alignment:)``) inside a
/// 20-point square hit target. Shared panel chrome; lives in `CmuxPanes`.
public struct PanelHeaderIconGlyph: View {
    private let systemName: String

    /// Create a header glyph for the given SF Symbol name.
    public init(systemName: String) {
        self.systemName = systemName
    }

    public var body: some View {
        Image(systemName: systemName)
            .cmuxSymbolRasterSize(13)
            .frame(width: 20, height: 20, alignment: .center)
            .contentShape(Rectangle())
    }
}
