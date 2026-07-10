import CmuxSimulator
import SwiftUI

struct SimulatorAccessibilityPagedTree: View {
    private static let pageSize = 50

    let rows: [SimulatorAccessibilityPresentationRow]
    let highlightedNodeID: String?
    let onSelect: (SimulatorAccessibilityNode) -> Void
    @State private var requestedPage = 0

    init(
        rows: [SimulatorAccessibilityPresentationRow],
        highlightedNodeID: String?,
        onSelect: @escaping (SimulatorAccessibilityNode) -> Void
    ) {
        self.rows = rows
        self.highlightedNodeID = highlightedNodeID
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(pageRows) { row in
                SimulatorAccessibilityTreeRow(
                    row: row,
                    isHighlighted: highlightedNodeID == row.node.id,
                    onSelect: onSelect
                )
            }
            if pageCount > 1 {
                HStack {
                    Button(simulatorStrings.previousPage) {
                        requestedPage = max(0, pageIndex - 1)
                    }
                    .disabled(pageIndex == 0)
                    Spacer()
                    Text(simulatorStrings.accessibilityPage(pageIndex + 1, pageCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(simulatorStrings.nextPage) {
                        requestedPage = min(pageCount - 1, pageIndex + 1)
                    }
                    .disabled(pageIndex + 1 >= pageCount)
                }
            }
        }
    }

    private var pageCount: Int {
        max(1, (rows.count + Self.pageSize - 1) / Self.pageSize)
    }

    private var pageIndex: Int {
        min(requestedPage, pageCount - 1)
    }

    private var pageRows: ArraySlice<SimulatorAccessibilityPresentationRow> {
        let start = pageIndex * Self.pageSize
        return rows[start..<min(start + Self.pageSize, rows.count)]
    }
}

private struct SimulatorAccessibilityTreeRow: View {
    let row: SimulatorAccessibilityPresentationRow
    let isHighlighted: Bool
    let onSelect: (SimulatorAccessibilityNode) -> Void

    var body: some View {
        Button { onSelect(row.node) } label: {
            HStack {
                Text(verbatim: row.node.label ?? row.node.role ?? row.node.id)
                    .lineLimit(1)
                    .padding(.leading, CGFloat(min(row.depth, 8)) * 10)
                Spacer()
                if isHighlighted { Image(systemName: "scope") }
            }
        }
        .buttonStyle(.plain)
    }
}
