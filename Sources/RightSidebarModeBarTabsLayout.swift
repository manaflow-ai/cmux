import SwiftUI

/// Marks the selected mode tab for `RightSidebarModeBarTabsLayout`.
struct RightSidebarModeBarTabSelectedKey: LayoutValueKey {
    static let defaultValue = false
}

/// Lays the right sidebar's mode tabs out from the leading edge with
/// `RightSidebarModeBarTabWidths`, so tabs shrink gradually as the sidebar
/// narrows and never grow past their full label.
struct RightSidebarModeBarTabsLayout: Layout {
    var spacing: CGFloat
    /// Receives the width the selected tab needs for its full label with
    /// every other tab at its icon.
    var widthReport: RightSidebarModeBarWidthReport?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        if let widthReport {
            let width = RightSidebarModeBarTabWidths.oneLabelWidth(
                natural: subviews.map { $0.sizeThatFits(.unspecified).width },
                floors: subviews.map { $0.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width }
            ) + gaps(subviews)
            MainActor.assumeIsolated { widthReport.note(tabsWidth: width) }
        }
        let widths = tabWidths(available: proposal.width, subviews: subviews)
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: widths.reduce(0, +) + gaps(subviews), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, tabWidths(available: bounds.width, subviews: subviews)) {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + spacing
        }
    }

    private func gaps(_ subviews: Subviews) -> CGFloat {
        spacing * CGFloat(max(0, subviews.count - 1))
    }

    private func tabWidths(available: CGFloat?, subviews: Subviews) -> [CGFloat] {
        let natural = subviews.map { $0.sizeThatFits(.unspecified).width }
        guard let available, available.isFinite else { return natural }
        return RightSidebarModeBarTabWidths(
            natural: natural,
            floors: subviews.map { $0.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width },
            selected: subviews.firstIndex { $0[RightSidebarModeBarTabSelectedKey.self] },
            available: available - gaps(subviews)
        ).widths
    }
}
