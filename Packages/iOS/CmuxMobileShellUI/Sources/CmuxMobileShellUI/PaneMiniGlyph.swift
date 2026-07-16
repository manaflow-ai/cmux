import CmuxMobileShell
import SwiftUI

/// Eighteen-by-thirteen spatial map of the workspace's Mac pane layout.
struct PaneMiniGlyph: View {
    let panes: [PaneRackPaneSnapshot]
    let highlightedPaneID: String
    let strokeColor: Color
    let fillColor: Color

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            let workspacePath = Path(roundedRect: bounds, cornerRadius: 2)
            context.clip(to: workspacePath)
            let layout = PaneMiniGlyphLayout(size: size)

            if let highlighted = panes.first(where: { $0.id == highlightedPaneID }) {
                context.fill(Path(layout.rect(for: highlighted.rect)), with: .color(fillColor))
            }
            for pane in panes {
                context.stroke(
                    Path(layout.rect(for: pane.rect)),
                    with: .color(strokeColor),
                    lineWidth: 0.5
                )
            }
            context.stroke(workspacePath, with: .color(strokeColor), lineWidth: 1)
        }
        .frame(width: 18, height: 13)
        .accessibilityHidden(true)
    }
}
