import AppKit
import SwiftUI

struct SidebarTopScrim: View {
    let height: CGFloat

    var body: some View {
        SidebarEdgeScrim(height: height, edge: .top)
    }
}

struct SidebarBottomScrim: View {
    let height: CGFloat

    var body: some View {
        SidebarEdgeScrim(height: height, edge: .bottom)
    }
}

struct SidebarEdgeScrim: View {
    enum Edge {
        case top
        case bottom
    }

    let height: CGFloat
    let edge: Edge

    var body: some View {
        SidebarEdgeBlurEffect()
            .frame(height: height)
            .mask(
                LinearGradient(
                    colors: gradientColors,
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    private var gradientColors: [Color] {
        let colors = [
            Color.black.opacity(0.95),
            Color.black.opacity(0.75),
            Color.black.opacity(0.35),
            Color.clear,
        ]
        switch edge {
        case .top:
            return colors
        case .bottom:
            return Array(colors.reversed())
        }
    }
}

struct SidebarEdgeBlurEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.material = .underWindowBackground
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
