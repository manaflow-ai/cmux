public import CoreGraphics
public import SwiftUI

/// The soft top/bottom edge fade applied as a `.mask` over the sidebar's
/// scrolling workspace area.
///
/// Renders a vertical stack of a top fade gradient, an opaque middle, and a
/// bottom fade gradient. The caller passes the resolved top and bottom fade
/// heights (a zero height collapses that edge to crisp). Intended for use as
/// the content of a `.mask { }` so it sizes to the masked area.
public struct SidebarWorkspaceScrollEdgeFadeMask: View {
    let topHeight: CGFloat
    let bottomHeight: CGFloat

    /// Creates the sidebar scroll edge fade mask.
    /// - Parameters:
    ///   - topHeight: Height of the top fade gradient; `0` keeps the top crisp.
    ///   - bottomHeight: Height of the bottom fade gradient; `0` keeps the bottom crisp.
    public init(topHeight: CGFloat, bottomHeight: CGFloat) {
        self.topHeight = topHeight
        self.bottomHeight = bottomHeight
    }

    public var body: some View {
        VStack(spacing: 0) {
            SidebarEdgeFadeGradient(edge: .top)
                .frame(height: topHeight)
            Rectangle()
                .fill(Color.black)
            SidebarEdgeFadeGradient(edge: .bottom)
                .frame(height: bottomHeight)
        }
    }
}

private struct SidebarEdgeFadeGradient: View {
    enum Edge {
        case top
        case bottom
    }

    let edge: Edge

    var body: some View {
        LinearGradient(
            colors: maskColors,
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var maskColors: [Color] {
        let colors = [
            Color.black.opacity(0.05),
            Color.black.opacity(0.25),
            Color.black.opacity(0.65),
            Color.black,
        ]
        switch edge {
        case .top:
            return colors
        case .bottom:
            return Array(colors.reversed())
        }
    }
}
