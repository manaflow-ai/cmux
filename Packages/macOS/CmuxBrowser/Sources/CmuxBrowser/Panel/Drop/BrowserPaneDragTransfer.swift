public import AppKit
public import Foundation

/// A tab being dragged onto a browser pane, decoded from a drag pasteboard.
/// Covers both Bonsplit tab transfers and file-preview transfers; the two
/// pasteboard types are injected by the app so this value stays free of the
/// app-side `DragOverlayRoutingPolicy`.
public struct BrowserPaneDragTransfer: Equatable {
    public let tabId: UUID
    public let sourcePaneId: UUID
    public let sourceProcessId: Int32
    public let kind: String?
    public let isFilePreviewTransfer: Bool

    public init(
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

    /// Whether the drag originated in this process (cross-process drops are
    /// ignored by the pane drop routing).
    public var isFromCurrentProcess: Bool {
        sourceProcessId == Int32(ProcessInfo.processInfo.processIdentifier)
    }

    /// Whether the transfer represents a file-preview tab rather than a normal
    /// Bonsplit browser tab.
    public var isFilePreview: Bool {
        isFilePreviewTransfer
    }

    /// Decodes a transfer from a drag pasteboard. File-preview transfers take
    /// precedence over Bonsplit tab transfers, matching the legacy ordering.
    /// `filePreviewTransferType` and `bonsplitTabTransferType` are the app's
    /// custom pasteboard types, injected to keep this value app-agnostic.
    public static func decode(
        from pasteboard: NSPasteboard,
        filePreviewTransferType: NSPasteboard.PasteboardType,
        bonsplitTabTransferType: NSPasteboard.PasteboardType
    ) -> BrowserPaneDragTransfer? {
        if let data = pasteboard.data(forType: filePreviewTransferType) {
            return decode(from: data, isFilePreviewTransfer: true)
        }
        if let raw = pasteboard.string(forType: filePreviewTransferType) {
            return decode(from: Data(raw.utf8), isFilePreviewTransfer: true)
        }
        if let data = pasteboard.data(forType: bonsplitTabTransferType) {
            return decode(from: data)
        }
        if let raw = pasteboard.string(forType: bonsplitTabTransferType) {
            return decode(from: Data(raw.utf8))
        }
        return nil
    }

    /// Decodes a transfer from raw JSON pasteboard data.
    public static func decode(from data: Data, isFilePreviewTransfer: Bool = false) -> BrowserPaneDragTransfer? {
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
