import CoreGraphics

/// Supplies deterministic estimates while AppKit resolves exact hosted SwiftUI row heights.
struct SidebarWorkspaceTableRowHeightCalculator {
    var defaultWorkspaceHeight: CGFloat {
        estimatedWorkspaceHeight(fontScale: 1, titleLineCount: 1, auxiliaryLineCount: 0)
    }

    func estimatedWorkspaceHeight(
        fontScale: CGFloat,
        titleLineCount: Int,
        auxiliaryLineCount: Int
    ) -> CGFloat {
        let scale = max(0.5, fontScale)
        let titleLines = max(1, titleLineCount)
        let auxiliaryLines = max(0, auxiliaryLineCount)
        let titleHeight = CGFloat(titleLines) * 15 * scale
        let auxiliaryHeight = CGFloat(auxiliaryLines) * 12 * scale
        let interlineSpacing = auxiliaryLines > 0 ? CGFloat(auxiliaryLines) * 4 : 0
        return ceil(16 + titleHeight + auxiliaryHeight + interlineSpacing)
    }

    func estimatedGroupHeaderHeight(fontScale: CGFloat) -> CGFloat {
        ceil(26 * max(0.5, fontScale) + 10)
    }
}
