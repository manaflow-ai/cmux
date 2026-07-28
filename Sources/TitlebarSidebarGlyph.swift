import SwiftUI

/// Draws the sidebar outline used by the built-in leading and trailing title-bar toggles.
struct TitlebarSidebarGlyph: View {
    enum Edge: Equatable {
        case leading
        case trailing
    }

    let edge: Edge
    let iconSize: CGFloat

    var body: some View {
        GlyphShape(edge: edge)
            .stroke(
                style: StrokeStyle(
                    lineWidth: HeaderChromeIconStyle.sidebarGlyphStrokeWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: max(13, iconSize + 2), height: max(11, iconSize - 1))
    }

    private struct GlyphShape: Shape {
        let edge: Edge

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let insetRect = rect.insetBy(dx: 0.5, dy: 0.5)
            path.addRoundedRect(
                in: insetRect,
                cornerSize: CGSize(width: 2, height: 2)
            )

            let dividerFraction = edge == .leading ? 0.36 : 0.64
            let dividerX = insetRect.minX + insetRect.width * dividerFraction
            path.move(to: CGPoint(x: dividerX, y: insetRect.minY + 1.5))
            path.addLine(to: CGPoint(x: dividerX, y: insetRect.maxY - 1.5))
            return path
        }
    }
}
