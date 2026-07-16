import CmuxMobileShellModel

extension MobileTerminalReorderIntent {
    /// Applies this validated final index to a pane-local identity order.
    func applying(
        to terminalIDs: [MobileTerminalPreview.ID]
    ) -> [MobileTerminalPreview.ID]? {
        guard let sourceIndex = terminalIDs.firstIndex(of: terminalID),
              terminalIDs.indices.contains(targetIndex) else {
            return nil
        }
        var result = terminalIDs
        let moved = result.remove(at: sourceIndex)
        result.insert(moved, at: targetIndex)
        return result
    }
}
