import AppKit

@MainActor
final class PaneDropRoutingSession {
    private var activeSequenceNumbers: Set<Int> = []

    var hasActiveDropDrag: Bool {
        !activeSequenceNumbers.isEmpty
    }

    func updateActiveDropDrag(_ sender: any NSDraggingInfo, operation: NSDragOperation) -> Bool {
        guard !operation.isEmpty else {
            clearActiveDropDrag(sender)
            return false
        }

        let types = sender.draggingPasteboard.types
        guard DragOverlayRoutingPolicy.hasBonsplitTabTransfer(types)
            || DragOverlayRoutingPolicy.hasFileDropPayload(types) else { return false }
        activeSequenceNumbers.insert(sender.draggingSequenceNumber)
        return true
    }

    func clearActiveDropDrag(_ sender: any NSDraggingInfo) {
        activeSequenceNumbers.remove(sender.draggingSequenceNumber)
    }

    func clearActiveDropDrag(sequenceNumber: Int) {
        activeSequenceNumbers.remove(sequenceNumber)
    }
}
