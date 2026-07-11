/// Resolves selection after an exact terminal disappears from a pane.
public struct MobileTerminalCloseFallback: Equatable, Sendable {
    /// The terminal being closed.
    public let closedTerminalID: MobileTerminalPreview.ID
    /// The selected terminal before the close.
    public let selectedTerminalID: MobileTerminalPreview.ID?
    /// The closing terminal's pane membership before mutation.
    public let orderedTerminalIDs: [MobileTerminalPreview.ID]

    /// Creates a deterministic close fallback snapshot.
    public init(
        closedTerminalID: MobileTerminalPreview.ID,
        selectedTerminalID: MobileTerminalPreview.ID?,
        orderedTerminalIDs: [MobileTerminalPreview.ID]
    ) {
        self.closedTerminalID = closedTerminalID
        self.selectedTerminalID = selectedTerminalID
        self.orderedTerminalIDs = orderedTerminalIDs
    }

    /// Chooses the terminal now at the closed index, otherwise the previous one.
    public func resolvedSelection(availableTerminalIDs: Set<MobileTerminalPreview.ID>) -> MobileTerminalPreview.ID? {
        guard selectedTerminalID == closedTerminalID,
              let closedIndex = orderedTerminalIDs.firstIndex(of: closedTerminalID) else {
            return selectedTerminalID.flatMap { availableTerminalIDs.contains($0) ? $0 : nil }
        }
        let survivors = orderedTerminalIDs.filter { $0 != closedTerminalID && availableTerminalIDs.contains($0) }
        guard !survivors.isEmpty else { return nil }
        return survivors[min(closedIndex, survivors.count - 1)]
    }
}
