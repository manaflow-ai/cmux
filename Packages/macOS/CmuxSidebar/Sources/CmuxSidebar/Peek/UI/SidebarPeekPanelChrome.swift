public import SwiftUI

/// The floating peek panel's frame: material, hairline rim, and shadow, with
/// the workspace list hosted inside it.
///
/// Content-agnostic on purpose. The list, the filter field, and the footer are
/// the same views the docked sidebar draws; only the frame around them changes
/// between modes, which is what makes float and dock feel like one surface in
/// two positions rather than two different sidebars.
public struct SidebarPeekPanelChrome<Content: View>: View {
    /// Geometry for the card.
    public let metrics: SidebarPeekPanelMetrics
    /// The AppKit material to blur the backdrop with.
    public let material: Material
    /// The panel's contents.
    @ViewBuilder public let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    /// Creates the panel frame.
    ///
    /// - Parameters:
    ///   - metrics: Card geometry.
    ///   - material: Backdrop material for the glass.
    ///   - content: The list and chrome to host.
    public init(
        metrics: SidebarPeekPanelMetrics = .default,
        material: Material = .regularMaterial,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.metrics = metrics
        self.material = material
        self.content = content
    }

    public var body: some View {
        content()
            .background(surface)
            .overlay(rim)
            .clipShape(shape)
            .shadow(
                color: .black.opacity(metrics.shadowOpacity),
                radius: metrics.shadowRadius,
                x: 0,
                y: metrics.shadowOffsetY
            )
            .padding(.leading, metrics.leadingInset)
            .padding(.top, metrics.topInset)
            .padding(.bottom, metrics.bottomInset)
            .accessibilityIdentifier("SidebarPeekPanel")
    }

    /// The card's ground: real behind-window glass with a legibility tint.
    ///
    /// The glass samples the terminal under the panel window; the tint is
    /// what keeps row labels readable over it. Blur alone leaves ghosted
    /// terminal text inside the card; the tint pushes it back to a shimmer
    /// without going opaque, which is the whole glassmorphism effect.
    private var surface: some View {
        ZStack {
            SidebarPeekGlassBackdrop(cornerRadius: metrics.cornerRadius)
            shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.52))
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
    }

    /// The rim: a hairline border plus a brighter top edge.
    ///
    /// The gradient is the whole gloss effect. A uniform border reads as a
    /// sticker; catching a little more light along the top edge and letting it
    /// fall off downward is what makes the card read as a pane of glass lying
    /// over the content rather than a rectangle drawn on it.
    private var rim: some View {
        shape.strokeBorder(
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.white.opacity(0.22), Color.white.opacity(0.06)]
                    : [Color.white.opacity(0.75), Color.black.opacity(0.10)],
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: metrics.borderWidth
        )
    }
}
