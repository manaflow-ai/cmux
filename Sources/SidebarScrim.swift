import SwiftUI

struct SidebarWorkspaceScrollEdgeFadeMask: View {
    let topHeight: CGFloat
    let bottomHeight: CGFloat

    var body: some View {
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
