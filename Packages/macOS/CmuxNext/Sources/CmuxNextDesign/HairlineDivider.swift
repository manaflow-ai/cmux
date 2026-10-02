public import SwiftUI

/// A one-point separator for SwiftUI chrome (use instead of
/// `Divider()`, whose system color ignores the theme and the switch). It
/// draws nothing under `appearance.borders` none (`Borders`) but keeps its
/// pixel, so layout does not move.
public struct HairlineDivider: View {
    public enum Axis: Sendable { case horizontal, vertical }

    private let color: Color
    private let axis: Axis

    public init(_ axis: Axis = .horizontal, color: Color) {
        self.axis = axis
        self.color = color
    }

    public var body: some View {
        // One point, as `Divider()`, so replacing it moves nothing.
        let pixel: CGFloat = 1
        Rectangle()
            .fill(Borders.drawsLines ? color : .clear)
            .frame(width: axis == .vertical ? pixel : nil, height: axis == .horizontal ? pixel : nil)
    }
}
