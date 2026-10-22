public import SwiftUI

extension View {
    /// The Liquid Glass button style (`.glass`, macOS 26 and later), or
    /// `.bordered` where Liquid Glass is missing
    /// (`Glass.isLiquidGlassAvailable`), with the pointing hand over it (`clickableCursor()`).
    @ViewBuilder
    public func glassButtonStyle() -> some View {
        if #available(macOS 26.0, *), Glass.isLiquidGlassAvailable {
            buttonStyle(.glass).clickableCursor()
        } else {
            buttonStyle(.bordered).clickableCursor()
        }
    }
}
