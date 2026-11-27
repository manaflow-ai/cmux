import CmuxFoundation
import CmuxTerminal
import CmuxTerminalCore
import Foundation

/// Selects one stable lineage when a request spans unordered panel stores.
struct TerminalFontSizeLineageSelection {
    private var panelIdSortKey: String?
    private(set) var lineage: TerminalFontSizeLineage?

    @MainActor
    mutating func consider(
        _ terminalPanel: TerminalPanel,
        magnificationPercent: Int =
            GlobalFontMagnification.storedPercent
    ) {
        consider(
            panelId: terminalPanel.id,
            lineage: terminalPanel.surface.fontSizeLineageSnapshot(
                magnificationPercent: magnificationPercent
            )
        )
    }

    mutating func consider(
        panelId: UUID,
        lineage candidateLineage: TerminalFontSizeLineage?
    ) {
        guard let candidateLineage else { return }
        let candidateSortKey = panelId.uuidString
        guard panelIdSortKey.map({ candidateSortKey < $0 }) ?? true else {
            return
        }
        panelIdSortKey = candidateSortKey
        lineage = candidateLineage
    }
}
