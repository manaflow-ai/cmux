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
        case .section(let section, let rowLimit, _, _, let isCollapsed, _, _, _):
            let isSearchResultsSection = section.key == SessionIndexView.searchResultsSectionKey
            let headerHeight: CGFloat = isSearchResultsSection
                ? 0
                : lineHeight(
                    baseFontSize: 13,
                    minimumContentHeight: 14,
                    verticalPadding: 6,
                    environment: environment
                )
            guard !isCollapsed else { return headerHeight }

            let entryHeight = lineHeight(
                baseFontSize: 13,
                // SessionRow reserves a 20-point agent icon frame so the
                // primary line stays aligned even when an icon asset is
                // unavailable.
                minimumContentHeight: 20,
                verticalPadding: 8,
                environment: environment
            )
            // Recency/search rows can carry a second subtitle line (folder ·
            // branch, message count); agree with SessionRow's layout.
            let subtitleHeight = lineHeight(
                baseFontSize: 11,
                minimumContentHeight: 0,
                verticalPadding: 1,
                environment: environment
            )
            var visibleEntryHeight: CGFloat = 0
            for entry in section.entries.prefix(rowLimit) {
                visibleEntryHeight += entryHeight
                if section.accessories[entry.id]?.hasSubtitle == true {
                    // SessionRow is a VStack with one point of spacing
                    // between its primary and metadata lines.
                    visibleEntryHeight += 1 + subtitleHeight
                }
            }
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
