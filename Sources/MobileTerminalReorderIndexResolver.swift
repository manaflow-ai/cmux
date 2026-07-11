import Foundation

/// Converts a terminal-only final index into Bonsplit's all-panel insertion index.
struct MobileTerminalReorderIndexResolver {
    static func destinationIndex(
        panePanelIDs: [UUID],
        terminalPanelIDs: Set<UUID>,
        movingPanelID: UUID,
        targetTerminalIndex: Int
    ) -> Int? {
        guard terminalPanelIDs.contains(movingPanelID),
              let sourceIndex = panePanelIDs.firstIndex(of: movingPanelID) else {
            return nil
        }
        let terminalCount = panePanelIDs.lazy.filter(terminalPanelIDs.contains).count
        guard targetTerminalIndex >= 0, targetTerminalIndex < terminalCount else { return nil }

        var remainingPanels = panePanelIDs
        remainingPanels.remove(at: sourceIndex)
        let remainingTerminals = remainingPanels.filter(terminalPanelIDs.contains)
        let insertionIndex: Int
        if targetTerminalIndex < remainingTerminals.count,
           let anchorIndex = remainingPanels.firstIndex(of: remainingTerminals[targetTerminalIndex]) {
            insertionIndex = anchorIndex
        } else if let lastTerminal = remainingTerminals.last,
                  let lastIndex = remainingPanels.firstIndex(of: lastTerminal) {
            insertionIndex = lastIndex + 1
        } else {
            insertionIndex = 0
        }

        return sourceIndex < insertionIndex ? insertionIndex + 1 : insertionIndex
    }
}
