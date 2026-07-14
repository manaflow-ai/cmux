import Foundation

/// Converts a terminal-only final index into Bonsplit's all-panel insertion index.
struct MobileTerminalReorderIndexResolver {
    let panePanelIDs: [UUID]
    let terminalPanelIDs: Set<UUID>
    let pinnedPanelIDs: Set<UUID>
    let movingPanelID: UUID

    init(
        panePanelIDs: [UUID],
        terminalPanelIDs: Set<UUID>,
        pinnedPanelIDs: Set<UUID> = [],
        movingPanelID: UUID
    ) {
        self.panePanelIDs = panePanelIDs
        self.terminalPanelIDs = terminalPanelIDs
        self.pinnedPanelIDs = pinnedPanelIDs
        self.movingPanelID = movingPanelID
    }

    func crossesPinnedBoundary(
        targetTerminalIndex: Int
    ) -> Bool {
        guard terminalPanelIDs.contains(movingPanelID) else { return false }
        let terminalCount = panePanelIDs.lazy.filter(terminalPanelIDs.contains).count
        guard targetTerminalIndex >= 0, targetTerminalIndex < terminalCount else { return false }
        let pinnedTerminalCount = panePanelIDs.lazy.filter {
            terminalPanelIDs.contains($0) && pinnedPanelIDs.contains($0)
        }.count
        return pinnedPanelIDs.contains(movingPanelID)
            ? targetTerminalIndex >= pinnedTerminalCount
            : targetTerminalIndex < pinnedTerminalCount
    }

    func destinationIndex(
        targetTerminalIndex: Int
    ) -> Int? {
        guard terminalPanelIDs.contains(movingPanelID),
              let sourceIndex = panePanelIDs.firstIndex(of: movingPanelID) else {
            return nil
        }
        let terminalCount = panePanelIDs.lazy.filter(terminalPanelIDs.contains).count
        guard targetTerminalIndex >= 0, targetTerminalIndex < terminalCount else { return nil }
        guard !crossesPinnedBoundary(
            targetTerminalIndex: targetTerminalIndex
        ) else { return nil }

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
