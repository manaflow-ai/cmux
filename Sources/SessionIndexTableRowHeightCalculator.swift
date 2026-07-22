import AppKit
import CmuxFoundation

/// Computes Vault table heights without instantiating offscreen SwiftUI rows.
@MainActor
final class SessionIndexTableRowHeightCalculator {
    private var fontHeightByPointSize: [CGFloat: CGFloat] = [:]

    func height(
        for row: SessionIndexTableRow,
        environment: SessionIndexTableEnvironmentSnapshot
    ) -> CGFloat {
        switch row {
        case .gap:
            return 4
        case .section(let section, let rowLimit, _, _, let isCollapsed, _, _, _, _):
            let headerHeight = lineHeight(
                baseFontSize: 13,
                minimumContentHeight: 14,
                verticalPadding: 6,
                environment: environment
            )
            guard !isCollapsed else { return headerHeight }

            let entryHeight = lineHeight(
                baseFontSize: 13,
                minimumContentHeight: 12,
                verticalPadding: 8,
                environment: environment
            )
            let visibleEntryHeight = CGFloat(min(section.entries.count, rowLimit)) * entryHeight
            let showMoreHeight: CGFloat
            if section.shouldOfferShowMore(rowLimit: rowLimit) {
                showMoreHeight = lineHeight(
                    baseFontSize: 12,
                    minimumContentHeight: 0,
                    verticalPadding: 8,
                    environment: environment
                )
            } else {
                showMoreHeight = 0
            }
            return headerHeight + visibleEntryHeight + showMoreHeight + 2
        }
    }

    private func lineHeight(
        baseFontSize: CGFloat,
        minimumContentHeight: CGFloat,
        verticalPadding: CGFloat,
        environment: SessionIndexTableEnvironmentSnapshot
    ) -> CGFloat {
        let pointSize = GlobalFontMagnification.scaledSize(
            baseFontSize,
            percent: environment.globalFontMagnificationPercent
        )
        let fontHeight: CGFloat
        if let cachedFontHeight = fontHeightByPointSize[pointSize] {
            fontHeight = cachedFontHeight
        } else {
            fontHeight = NSFont.systemFont(ofSize: pointSize).boundingRectForFont.height
            fontHeightByPointSize[pointSize] = fontHeight
        }
        return ceil(max(fontHeight, minimumContentHeight) + verticalPadding)
    }
}
