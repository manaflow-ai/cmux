import CoreGraphics

enum SidebarWorkspaceChecklistPopoverViewportModel {
    static let maximumVisibleRowCount = 6

    static func visibleRowCount(forItemCount count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(count, maximumVisibleRowCount)
    }

    static func requiresScrolling(forItemCount count: Int) -> Bool {
        count > maximumVisibleRowCount
    }

    static func viewportHeight<ID: Hashable>(
        orderedIds: [ID],
        rowFrames: [ID: CGRect],
        fallbackRowHeight: CGFloat,
        fallbackSpacing: CGFloat
    ) -> CGFloat {
        let visibleCount = visibleRowCount(forItemCount: orderedIds.count)
        guard visibleCount > 0 else { return 0 }
        let visibleIds = orderedIds.prefix(visibleCount)
        let visibleFrames = visibleIds.compactMap { rowFrames[$0] }
        if visibleFrames.count == visibleCount,
           let first = visibleFrames.first,
           let last = visibleFrames.last {
            return max(0, last.maxY - first.minY)
        }
        return fallbackRowHeight * CGFloat(visibleCount)
            + fallbackSpacing * CGFloat(visibleCount - 1)
    }
}
