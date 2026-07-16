/// A validated terminal reorder confined to one workspace and pane.
public struct MobileTerminalReorderIntent: Equatable, Sendable {
    /// The terminal being moved.
    public let terminalID: MobileTerminalPreview.ID
    /// The pane that owns both source and destination.
    public let paneID: MobilePanePreview.ID
    /// The destination insertion index expected by the Mac.
    public let targetIndex: Int

    /// Resolves a SwiftUI move into a strict same-pane mutation.
    public init?(
        terminalID: MobileTerminalPreview.ID,
        sourceIndex: Int,
        destinationIndex: Int,
        pane: MobilePanePreview
    ) {
        guard pane.terminalIDs.indices.contains(sourceIndex),
              pane.terminalIDs[sourceIndex] == terminalID,
              destinationIndex >= 0,
              destinationIndex <= pane.terminalIDs.count,
              destinationIndex != sourceIndex,
              destinationIndex != sourceIndex + 1 else {
            return nil
        }
        self.terminalID = terminalID
        self.paneID = pane.id
        self.targetIndex = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
    }
}
