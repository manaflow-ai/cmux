import AppKit
import Foundation

struct BrowserPaneDragTransfer: Equatable {
    let tabId: UUID
    let sourcePaneId: UUID
    let sourceProcessId: Int32
    let kind: String?
    let isFilePreviewTransfer: Bool

    init(
        tabId: UUID,
        sourcePaneId: UUID,
        sourceProcessId: Int32,
        kind: String? = nil,
        isFilePreviewTransfer: Bool = false
    ) {
        self.tabId = tabId
        self.sourcePaneId = sourcePaneId
        self.sourceProcessId = sourceProcessId
        self.kind = kind
        self.isFilePreviewTransfer = isFilePreviewTransfer
    }

    var isFromCurrentProcess: Bool {
        sourceProcessId == Int32(ProcessInfo.processInfo.processIdentifier)
    }

    var isFilePreview: Bool {
        isFilePreviewTransfer
    }

    static func decode(from pasteboard: NSPasteboard) -> BrowserPaneDragTransfer? {
        if let data = pasteboard.data(forType: DragOverlayRoutingPolicy.filePreviewTransferType) {
            return decode(from: data, isFilePreviewTransfer: true)
        }
        if let raw = pasteboard.string(forType: DragOverlayRoutingPolicy.filePreviewTransferType) {
            return decode(from: Data(raw.utf8), isFilePreviewTransfer: true)
        }
        if let data = pasteboard.data(forType: DragOverlayRoutingPolicy.bonsplitTabTransferType) {
            return decode(from: data)
        }
        if let raw = pasteboard.string(forType: DragOverlayRoutingPolicy.bonsplitTabTransferType) {
            return decode(from: Data(raw.utf8))
        }
        return nil
    }

    static func decode(from data: Data, isFilePreviewTransfer: Bool = false) -> BrowserPaneDragTransfer? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tab = json["tab"] as? [String: Any],
              let tabIdRaw = tab["id"] as? String,
              let tabId = UUID(uuidString: tabIdRaw),
              let sourcePaneIdRaw = json["sourcePaneId"] as? String,
              let sourcePaneId = UUID(uuidString: sourcePaneIdRaw) else {
            return nil
        }

        let sourceProcessId = (json["sourceProcessId"] as? NSNumber)?.int32Value ?? -1
        let kind = tab["kind"] as? String
        return BrowserPaneDragTransfer(
            tabId: tabId,
            sourcePaneId: sourcePaneId,
            sourceProcessId: sourceProcessId,
            kind: kind,
            isFilePreviewTransfer: isFilePreviewTransfer
        )
    }
}
