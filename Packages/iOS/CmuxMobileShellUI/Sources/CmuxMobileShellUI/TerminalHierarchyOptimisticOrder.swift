import CmuxMobileShellModel

/// Applies one validated final terminal index to a pane-local identity order.
struct TerminalHierarchyOptimisticOrder {
    static func applying(
        _ intent: MobileTerminalReorderIntent,
        to terminalIDs: [MobileTerminalPreview.ID]
    ) -> [MobileTerminalPreview.ID]? {
        guard let sourceIndex = terminalIDs.firstIndex(of: intent.terminalID),
              terminalIDs.indices.contains(intent.targetIndex) else {
            return nil
        }
        var result = terminalIDs
        let moved = result.remove(at: sourceIndex)
        result.insert(moved, at: intent.targetIndex)
        return result
    }
}
