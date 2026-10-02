public import SwiftUI

/// A one-device-pixel separator for SwiftUI chrome (use instead of
/// `Divider()`, whose system color ignores the theme and the switch). It
/// draws nothing under `appearance.borders` none (`Borders`) but keeps its
/// pixel, so layout does not move.
public struct HairlineDivider: View {
    public enum Axis: Sendable { case horizontal, vertical }

    private let color: Color
    private let axis: Axis
    @Environment(\.displayScale) private var scale

    public init(_ axis: Axis = .horizontal, color: Color) {
        self.axis = axis
        self.color = color
    }

    public var body: some View {
        let pixel = 1 / max(scale, 1)
        Rectangle()
            .fill(Borders.drawsLines ? color : .clear)
            .frame(width: axis == .vertical ? pixel : nil, height: axis == .horizontal ? pixel : nil)
    }
}
