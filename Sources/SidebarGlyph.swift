import SwiftUI

/// The edge on which a sidebar glyph's divider is drawn.
enum SidebarGlyphSide: Sendable {
    case leading
    case trailing

    var dividerFraction: CGFloat {
        switch self {
        case .leading:
            return 0.36
        case .trailing:
            return 0.64
        }
    }
}

/// Draws the compact sidebar outline used by titlebar and right-sidebar chrome.
struct SidebarGlyph: View {
    let iconSize: CGFloat
    let side: SidebarGlyphSide

    var body: some View {
        SidebarGlyphShape(side: side)
            .stroke(
                style: StrokeStyle(
                    lineWidth: HeaderChromeIconStyle.sidebarGlyphStrokeWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: max(13, iconSize + 2), height: max(11, iconSize - 1))
    }
}

/// The outline path for a sidebar glyph, with a configurable divider edge.
struct SidebarGlyphShape: Shape {
    let side: SidebarGlyphSide

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let insetRect = rect.insetBy(dx: 0.5, dy: 0.5)
        path.addRoundedRect(
            in: insetRect,
            cornerSize: CGSize(width: 2, height: 2)
        )

        let dividerX = insetRect.minX + insetRect.width * side.dividerFraction
        path.move(to: CGPoint(x: dividerX, y: insetRect.minY + 1.5))
        path.addLine(to: CGPoint(x: dividerX, y: insetRect.maxY - 1.5))
        return path
    }
}
