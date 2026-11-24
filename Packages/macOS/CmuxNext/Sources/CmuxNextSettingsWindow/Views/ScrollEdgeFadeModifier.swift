import AppKit
import CmuxNextDesign
import SwiftUI

/// `ScrollEdgeFade` for SwiftUI scroll views: an alpha mask that fades the
/// top or bottom edge only while content is hidden beyond it, from the
/// scroll geometry (no polling), with the Motion `hover` fade (a short
/// crossfade under Reduce Motion). A mask, not a color, so it matches every
/// theme. Content insets are not visible
/// area, and overscroll past an end counts as that end.
struct ScrollEdgeFadeModifier: ViewModifier {
    @State private var edges: ScrollEdges = []

    func body(content: Content) -> some View {
        tracked(content)
            .mask {
                GeometryReader { proxy in
                    LinearGradient(stops: Self.stops(edges: edges, height: proxy.size.height), startPoint: .top, endPoint: .bottom)
                }
            }
    }

    /// The eased bands of `ScrollEdgeFadeView`: smoothstep from the edge to full ink, the bottom
    /// band taller than the top's, so neither ends in a line.
    static func stops(edges: ScrollEdges, height: CGFloat) -> [Gradient.Stop] {
        let h = max(height, 1), n = ScrollEdgeFadeView.bandSamples
        let top = min(Metrics.scrollEdgeFade / h, 0.4), bottom = min(Metrics.scrollEdgeFadeBottom / h, 0.4)
        let topStops = (0...n).map { i -> Gradient.Stop in
            let t = CGFloat(i) / CGFloat(n)
            return .init(color: .black.opacity(edges.contains(.top) ? ScrollEdgeFadeView.ease(t) : 1), location: top * t)
        }
        let bottomStops = (0...n).map { i -> Gradient.Stop in
            let t = CGFloat(i) / CGFloat(n)
            return .init(color: .black.opacity(edges.contains(.bottom) ? ScrollEdgeFadeView.ease(1 - t) : 1), location: 1 - bottom + bottom * t)
        }
        return topStops + bottomStops
    }

    /// Tracks the hidden edges from the scroll geometry on macOS 15 and newer;
    /// macOS 14 has no scroll geometry callback, so its edges never fade.
    @ViewBuilder
    private func tracked(_ content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
                    let insets = geometry.contentInsets
                    return ScrollEdges.hidden(
                        clipBounds: CGRect(origin: geometry.contentOffset, size: geometry.containerSize),
                        insets: NSEdgeInsets(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing),
                        document: CGRect(origin: .zero, size: geometry.contentSize),
                        isFlipped: true
                    )
                } action: { _, new in
                    // motion-allow: the curve and duration come from Motion.animation(.hover)
                    withAnimation(Motion.feedback.animation(.hover)) { edges = new }
                }
        } else {
            content
        }
    }
}

extension View {
    /// Fades the scroll view's edges that have content hidden beyond them.
    func scrollEdgeFade() -> some View { modifier(ScrollEdgeFadeModifier()) }

}
