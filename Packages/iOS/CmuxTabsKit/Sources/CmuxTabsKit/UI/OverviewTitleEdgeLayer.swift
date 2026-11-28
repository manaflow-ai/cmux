#if os(iOS)
import SwiftUI

/// Read once per launch: Release always draws the default edge.
let overviewTitleEdgeStyle = OverviewTitleEdgeStyle.current(environment: ProcessInfo.processInfo.environment)

/// The grid's top edge under the title bar. Opaque in the background color (with a material
/// under it, so a card's picture blurs as it reaches the edge) down to `edge.opaqueBottom`, then
/// fading to clear at `edge.height`. Cards never show through the header's text.
struct OverviewTitleEdgeLayer: View {
    let edge: OverviewTitleEdge
    let color: Color
    /// The gallery's progressive-blur variant: a thicker material over a longer fade.
    let strongBlur: Bool

    var body: some View {
        let mask = LinearGradient(stops: [.init(color: .black, location: 0),
                                          .init(color: .black, location: edge.opaqueStop),
                                          .init(color: .clear, location: 1)],
                                  startPoint: .top, endPoint: .bottom)
        ZStack {
            Rectangle().fill(strongBlur ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.ultraThinMaterial))
            // Over the progressive blur's tail the color thins first, so the blur reads.
            if strongBlur {
                LinearGradient(stops: [.init(color: color, location: 0),
                                       .init(color: color, location: edge.opaqueStop),
                                       .init(color: color.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                Rectangle().fill(color)
            }
        }
        .mask(mask)
        .frame(height: edge.height)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
