import AppKit
import Bonsplit
import Foundation

struct BrowserPaneDragTransfer: Equatable {
    let tabId: UUID
    let sourcePaneId: UUID
    let kind: String?
    let isFilePreviewTransfer: Bool

    init(
        tabId: UUID,
        sourcePaneId: UUID,
        kind: String? = nil,
        isFilePreviewTransfer: Bool = false
    ) {
        self.tabId = tabId
        self.sourcePaneId = sourcePaneId
        self.kind = kind
        self.isFilePreviewTransfer = isFilePreviewTransfer
    }

    var isFilePreview: Bool {
        isFilePreviewTransfer
    }

    static func decode(from pasteboard: NSPasteboard) -> BrowserPaneDragTransfer? {
        guard let transfer = BonsplitTabDragPayload.liveTransfer(from: pasteboard) else {
            return nil
        }
        return BrowserPaneDragTransfer(
            tabId: transfer.tab.id.uuid,
            sourcePaneId: transfer.sourcePaneId.id,
            kind: transfer.tab.kind,
            isFilePreviewTransfer: DragOverlayRoutingPolicy.hasFilePreviewTransfer(
                pasteboard.types
            )
        )
    }
}
