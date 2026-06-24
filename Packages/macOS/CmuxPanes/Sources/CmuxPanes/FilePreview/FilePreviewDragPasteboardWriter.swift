public import AppKit
public import Foundation

/// `NSPasteboardWriting` source for a file-preview tab drag.
///
/// Produced by the file explorer when the user drags a file-preview row out as
/// a tab. It registers the dragged file in ``FilePreviewDragRegistry`` under a
/// freshly minted id, then writes three pasteboard representations: the cmux
/// file-preview transfer type, the bonsplit tab-transfer type (so a bonsplit
/// tab bar accepts it), and a plain `fileURL` (so generic file-drop targets
/// accept it). The cmux/bonsplit representations carry only the encoded
/// ``MirrorTabTransferData`` (the registry id plus a mirror of the tab item);
/// the drop site decodes the id and looks the real ``FilePreviewDragEntry``
/// back up.
///
/// Faithful-lift note: the JSON shape of `MirrorTabTransferData`/`MirrorTabItem`,
/// the three written types, the drag-pasteboard mirroring side effect, and the
/// `UUID()` source-pane id / process-id fields are byte-identical to the former
/// `Sources/Panels/FilePreviewPanel.swift` declaration so existing drags
/// round-trip across builds. `NSObject` + the main-thread `DispatchQueue` mirror
/// hop are required by the synchronous AppKit drag contract; modernization
/// (async API) is a separate change.
///
/// The two pasteboard type identifiers are published here as public constants
/// so the writer is self-contained inside `CmuxPanes`. The app's
/// `DragOverlayRoutingPolicy.filePreviewTransferType` /
/// `bonsplitTabTransferType` hold the identical strings; both sides resolve to
/// the same `NSPasteboard.PasteboardType`, so the wire format is unchanged.
public final class FilePreviewDragPasteboardWriter: NSObject, NSPasteboardWriting {
    /// Mirror of a tab item carried inside a file-preview tab drag payload.
    ///
    /// Only `id` is consumed on the drop path (it keys ``FilePreviewDragRegistry``);
    /// the remaining fields exist to keep the JSON shape compatible with the
    /// bonsplit tab-transfer contract.
    private struct MirrorTabItem: Codable {
        let id: UUID
        let title: String
        let hasCustomTitle: Bool
        let icon: String?
        let iconImageData: Data?
        let kind: String?
        let isDirty: Bool
        let showsNotificationBadge: Bool
        let isLoading: Bool
        let isPinned: Bool
    }

    /// The full drag payload encoded onto the pasteboard: the mirrored tab item
    /// plus the source pane/process identity.
    private struct MirrorTabTransferData: Codable {
        let tab: MirrorTabItem
        let sourcePaneId: UUID
        let sourceProcessId: Int32
    }

    /// The cmux file-preview transfer pasteboard type (`com.cmux.filepreview.transfer`).
    ///
    /// Identical string to the app's `DragOverlayRoutingPolicy.filePreviewTransferType`.
    public static let filePreviewTransferType = NSPasteboard.PasteboardType("com.cmux.filepreview.transfer")

    /// The bonsplit tab-transfer pasteboard type (`com.splittabbar.tabtransfer`).
    ///
    /// Identical string to the app's `DragOverlayRoutingPolicy.bonsplitTabTransferType`.
    public static let bonsplitTransferType = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")

    private let filePath: String
    private let displayTitle: String
    private var transferData: Data?
    private var didMirrorTransferDataToDragPasteboard = false

    /// Creates a writer for the file at `filePath` shown as `displayTitle`.
    public init(filePath: String, displayTitle: String) {
        self.filePath = filePath
        self.displayTitle = displayTitle
        super.init()
    }

    /// Decodes the registry id from an encoded ``MirrorTabTransferData`` blob, or
    /// `nil` if `transferData` is not a valid payload.
    public static func dragID(from transferData: Data) -> UUID? {
        guard let transfer = try? JSONDecoder().decode(MirrorTabTransferData.self, from: transferData) else {
            return nil
        }
        return transfer.tab.id
    }

    /// Decodes the registry id from `pasteboard`, checking both transfer types
    /// and both the data and string representations.
    public static func dragID(from pasteboard: NSPasteboard) -> UUID? {
        for type in [Self.filePreviewTransferType, Self.bonsplitTransferType] {
            if let data = pasteboard.data(forType: type),
               let id = dragID(from: data) {
                return id
            }
            if let raw = pasteboard.string(forType: type),
               let id = dragID(from: Data(raw.utf8)) {
                return id
            }
        }
        return nil
    }

    /// Discards the registry entry referenced by `pasteboard` (if any) and sweeps
    /// any expired entries.
    public static func discardRegisteredDrag(from pasteboard: NSPasteboard) {
        if let id = dragID(from: pasteboard) {
            FilePreviewDragRegistry.shared.discard(id: id)
        }
        FilePreviewDragRegistry.shared.discardExpired()
    }

    private func transferDataForDrag() -> Data {
        if let transferData {
            return transferData
        }

        let dragId = FilePreviewDragRegistry.shared.register(
            FilePreviewDragEntry(filePath: filePath, displayTitle: displayTitle)
        )
        let transfer = MirrorTabTransferData(
            tab: MirrorTabItem(
                id: dragId,
                title: displayTitle,
                hasCustomTitle: false,
                icon: FilePreviewMode.initialTabIconName(for: URL(fileURLWithPath: filePath)),
                iconImageData: nil,
                kind: "filePreview",
                isDirty: false,
                showsNotificationBadge: false,
                isLoading: false,
                isPinned: false
            ),
            sourcePaneId: UUID(),
            sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier)
        )
        let data = (try? JSONEncoder().encode(transfer)) ?? Data()
        transferData = data
        return data
    }

    public func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        let data = transferDataForDrag()
        mirrorTransferDataToDragPasteboard(data)
        return [
            Self.filePreviewTransferType,
            Self.bonsplitTransferType,
            .fileURL
        ]
    }

    public func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == Self.bonsplitTransferType || type == Self.filePreviewTransferType {
            let data = transferDataForDrag()
            mirrorTransferDataToDragPasteboard(data)
            return data
        }
        if type == .fileURL {
            let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
            return fileURL.absoluteString
        }
        return nil
    }

    private func mirrorTransferDataToDragPasteboard(_ transferData: Data) {
        guard !didMirrorTransferDataToDragPasteboard else { return }
        didMirrorTransferDataToDragPasteboard = true
        let fileURLString = URL(fileURLWithPath: filePath).standardizedFileURL.absoluteString
        let write = { [transferData, fileURLString] in
            let pasteboard = NSPasteboard(name: .drag)
            pasteboard.addTypes([Self.filePreviewTransferType, Self.bonsplitTransferType, .fileURL], owner: nil)
            pasteboard.setData(transferData, forType: Self.bonsplitTransferType)
            pasteboard.setData(transferData, forType: Self.filePreviewTransferType)
            pasteboard.setString(fileURLString, forType: .fileURL)
        }
        if Thread.isMainThread {
            write()
        } else {
            DispatchQueue.main.async(execute: write)
        }
    }
}
