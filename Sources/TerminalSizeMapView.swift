import CmuxTerminalSharing
import CmuxTerminalSizing
import SwiftUI

/// Every attached window's outline against the terminal grid.
struct TerminalSizeMapView: View {
    let snapshot: TerminalSharingSnapshot

    var body: some View {
        Canvas { context, size in
            let state = snapshot.state
            let viewports = state.participants.compactMap { row in row.participant.viewport.map { (row, $0) } }
            let maxCols = CGFloat(max(state.cols, viewports.map(\.1.cols).max() ?? 0, 1))
            let maxRows = CGFloat(max(state.rows, viewports.map(\.1.rows).max() ?? 0, 1))
            let pad: CGFloat = 8
            // Cells are about twice as tall as wide.
            let scale = min((size.width - 2 * pad) / maxCols, (size.height - 2 * pad) / (maxRows * 2.05))
            func rect(_ grid: TerminalGridSize) -> CGRect {
                CGRect(x: pad, y: pad, width: CGFloat(grid.cols) * scale, height: CGFloat(grid.rows) * scale * 2.05)
            }
            let ownerColor = snapshot.owner.map { TerminalSharingDisplay.color(for: $0.participant) } ?? .secondary
            let gridRect = rect(state.size)
            context.fill(Path(gridRect), with: .color(ownerColor.opacity(0.16)))
            context.stroke(Path(gridRect), with: .color(ownerColor), lineWidth: 2)
            for (row, viewport) in viewports {
                let color = TerminalSharingDisplay.color(for: row.participant)
                context.stroke(
                    Path(rect(viewport)),
                    with: .color(color.opacity(row.counts ? 0.9 : 0.55)),
                    style: StrokeStyle(lineWidth: 1.2, dash: row.counts ? [] : [3, 3])
                )
            }
            context.draw(
                Text(TerminalSharingDisplay.compactGridLabel(state.size)).font(.system(size: 10, design: .monospaced)),
                at: CGPoint(x: gridRect.maxX - 4, y: gridRect.maxY - 5),
                anchor: .bottomTrailing
            )
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(String(localized: "terminalSharing.panel.map", defaultValue: "Size map: each window outline against the terminal size"))
    }
}
