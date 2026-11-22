public import SwiftUI

extension View {
    /// Draws the `Icon` views inside in `style`.
    public func iconStyle(_ style: IconStyle) -> some View {
        environment(\.iconStyle, style)
    }

    /// Draws the `Icon` views inside with `accent` (Cat drawings for Line).
    public func iconAccent(_ accent: IconAccent, color: Color? = nil) -> some View {
        environment(\.iconAccent, accent).environment(\.iconAccentColor, color)
    }
}
