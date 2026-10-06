import SwiftUI

/// Places filter labels in as many rows as the available page width requires.
struct HistoryFilterLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache,
    ) -> CGSize {
        let rows = rows(for: proposal.width, subviews: subviews)
        let size = rows.reduce(into: CGSize.zero) { result, row in
            result.width = max(result.width, row.width)
            result.height += row.height
        }
        return CGSize(width: size.width, height: size.height + verticalSpacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache,
    ) {
        let rows = rows(for: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size),
                )
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private func rows(for proposedWidth: CGFloat?, subviews: Subviews) -> [Row] {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let availableWidth = proposedWidth ?? sizes.reduce(0) { $0 + $1.width + horizontalSpacing }
        var rows: [Row] = []
        var current = Row()

        for (index, size) in sizes.enumerated() {
            let nextWidth = current.indices.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            if !current.indices.isEmpty && nextWidth > availableWidth {
                rows.append(current)
                current = Row()
            }
            current.indices.append(index)
            current.width = current.indices.count == 1 ? size.width : current.width + horizontalSpacing + size.width
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
}

