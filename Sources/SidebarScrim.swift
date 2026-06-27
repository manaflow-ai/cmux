import CmuxSettings
import SwiftUI

struct SidebarWorkspaceScrollEdgeFadeMask: View {
    let topHeight: CGFloat
    let bottomHeight: CGFloat
    let fadeStyle: SidebarScrollEdgeFadeStyle

    var body: some View {
        VStack(spacing: 0) {
            if topHeight > 0 {
                SidebarEdgeFadeGradient(edge: .top, fadeStyle: fadeStyle)
                    .frame(height: topHeight)
            }
            Rectangle()
                .fill(Color.black)
            if bottomHeight > 0 {
                SidebarEdgeFadeGradient(edge: .bottom, fadeStyle: fadeStyle)
                    .frame(height: bottomHeight)
            }
        }
    }
}

private struct SidebarEdgeFadeGradient: View {
    enum Edge {
        case top
        case bottom
    }

    let edge: Edge
    let fadeStyle: SidebarScrollEdgeFadeStyle

    var body: some View {
        LinearGradient(
            colors: maskColors,
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var maskColors: [Color] {
        let colors = fadeStyle.maskColors
        switch edge {
        case .top:
            return colors
        case .bottom:
            return Array(colors.reversed())
        }
    }
}

private extension SidebarScrollEdgeFadeStyle {
    var maskColors: [Color] {
        switch self {
        case .full:
            return [
                Color.black.opacity(0.05),
                Color.black.opacity(0.25),
                Color.black.opacity(0.65),
                Color.black,
            ]
        case .subtle:
            return [
                Color.black.opacity(0.45),
                Color.black.opacity(0.68),
                Color.black.opacity(0.88),
                Color.black,
            ]
        case .off:
            return [Color.black, Color.black]
        }
    }
}
