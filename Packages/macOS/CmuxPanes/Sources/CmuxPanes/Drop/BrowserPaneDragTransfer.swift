public import AppKit
public import Foundation

/// A decoded payload describing a tab being dragged into a browser pane.
///
/// Produced by decoding either a bonsplit tab-transfer pasteboard payload or a
/// file-preview transfer payload. The two pasteboard type identifiers are
/// injected by the caller (the app owns the `NSPasteboard` UTType constants),
/// so this value type stays free of any app-side pasteboard policy.
public struct BrowserPaneDragTransfer: Equatable, Sendable {
    /// The dragged tab's identity.
    public let tabId: UUID
    /// The pane the tab is being dragged from.
    public let sourcePaneId: UUID
    /// The process id of the dragging app, used to detect cross-process drags.
    public let sourceProcessId: Int32
    /// The tab kind string, when present in the bonsplit payload.
    public let kind: String?
    /// Whether the payload came from the file-preview transfer pasteboard type.
    public let isFilePreviewTransfer: Bool

    /// Creates a browser-pane drag transfer.
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

    /// Whether the drag originated in this process.
    public var isFromCurrentProcess: Bool {
        sourceProcessId == Int32(ProcessInfo.processInfo.processIdentifier)
    }

    /// Whether the drag is a file-preview transfer.
    public var isFilePreview: Bool {
        isFilePreviewTransfer
    }

    /// Decodes a drag transfer from a pasteboard, preferring a file-preview
    /// payload over a bonsplit tab payload.
    ///
    /// - Parameters:
    ///   - pasteboard: The drag pasteboard to read.
    ///   - filePreviewTransferType: The pasteboard type identifying a
    ///     file-preview transfer payload (app-owned UTType constant).
    ///   - bonsplitTabTransferType: The pasteboard type identifying a bonsplit
    ///     tab-transfer payload (app-owned UTType constant).
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

    /// Decodes a drag transfer from raw JSON payload bytes.
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
