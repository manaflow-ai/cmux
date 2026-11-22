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
                withAnimation(Motion.animation(.hover)) { edges = new }
            }
            .mask {
                GeometryReader { proxy in
                    let fade = min(Metrics.scrollEdgeFade / max(proxy.size.height, 1), 0.4)
                    LinearGradient(stops: [
                        .init(color: edges.contains(.top) ? .clear : .black, location: 0),
                        .init(color: .black, location: edges.contains(.top) ? fade : 0),
                        .init(color: .black, location: edges.contains(.bottom) ? 1 - fade : 1),
                        .init(color: edges.contains(.bottom) ? .clear : .black, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
            }
    }
}

extension View {
    /// Fades the scroll view's edges that have content hidden beyond them.
    func scrollEdgeFade() -> some View { modifier(ScrollEdgeFadeModifier()) }
}
