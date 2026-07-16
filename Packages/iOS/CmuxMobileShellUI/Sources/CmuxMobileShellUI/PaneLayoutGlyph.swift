import CmuxMobileShellModel
import SwiftUI

/// A miniature of the workspace's REAL split layout, drawn from the layout
/// tree: one rounded rect per pane, subdivided by the actual orientations and
/// divider ratios. The pane containing the selected tab renders brighter, so
/// the map button doubles as a "you are here" indicator.
struct PaneLayoutGlyph: View {
    let layout: MobileWorkspacePaneLayout
    let selectedTabID: MobileTerminalPreview.ID?
    var lineColor: Color
    var highlightColor: Color

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            draw(node: layout.root, in: bounds, context: &context)
        }
        .accessibilityHidden(true)
    }

    private func draw(node: MobileWorkspacePaneLayout.Node, in rect: CGRect, context: inout GraphicsContext) {
        switch node {
        case let .pane(pane):
            let inset = rect.insetBy(dx: 0.75, dy: 0.75)
            guard inset.width > 1, inset.height > 1 else { return }
            let path = Path(roundedRect: inset, cornerRadius: 1.5)
            let containsSelection = selectedTabID.map { id in
                pane.tabs.contains { $0.id == id }
            } ?? false
            if containsSelection {
                context.fill(path, with: .color(highlightColor))
            } else {
                context.stroke(path, with: .color(lineColor), lineWidth: 1)
            }
        case let .split(orientation, ratio, first, second):
            let clamped = min(max(ratio, 0.15), 0.85)
            let (firstRect, secondRect): (CGRect, CGRect)
            switch orientation {
            case .horizontal:
                let firstWidth = rect.width * clamped
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
                secondRect = CGRect(
                    x: rect.minX + firstWidth, y: rect.minY,
                    width: rect.width - firstWidth, height: rect.height
                )
            case .vertical:
                let firstHeight = rect.height * clamped
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight)
                secondRect = CGRect(
                    x: rect.minX, y: rect.minY + firstHeight,
                    width: rect.width, height: rect.height - firstHeight
                )
            }
            draw(node: first, in: firstRect, context: &context)
            draw(node: second, in: secondRect, context: &context)
        }
    }
}
