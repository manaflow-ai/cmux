public import AppKit
public import Foundation
import CmuxFoundation

/// `NSPasteboardWriting` adapter that begins a file-preview drag.
///
/// When a file-preview tab (or a file-explorer node) starts a drag, AppKit asks
/// this writer for the pasteboard types it can vend and their payloads. The
/// writer lazily synthesizes a tab-transfer JSON payload, registers the drag in
/// ``FilePreviewDragRegistry/shared`` so a pane drop target can resolve it by id,
/// and mirrors the payload onto the live `.drag` pasteboard so Bonsplit's
/// tab-bar drop path and the file-preview drop path both see it.
public final class FilePreviewDragPasteboardWriter: NSObject, NSPasteboardWriting {
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

    private struct MirrorTabTransferData: Codable {
        let tab: MirrorTabItem
        let sourcePaneId: UUID
        let sourceProcessId: Int32
    }

    /// Bonsplit's tab-transfer pasteboard type, mirrored so a dragged file
    /// preview can be dropped onto the tab bar.
    public static let bonsplitTransferType = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")

    /// The file-preview drag pasteboard type. This is the single source of truth
    /// for the identifier; the app's drag-routing policy forwards to it.
    public static let filePreviewTransferType = NSPasteboard.PasteboardType("com.cmux.filepreview.transfer")

    private let filePath: String
    private let displayTitle: String
    private var transferData: Data?
    private var didMirrorTransferDataToDragPasteboard = false

    /// Creates a writer for the file at `filePath`, shown as `displayTitle`.
    public init(filePath: String, displayTitle: String) {
        self.filePath = filePath
        self.displayTitle = displayTitle
        super.init()
    }

    /// Decodes the drag id stamped onto a tab-transfer payload, or `nil`.
    public static func dragID(from transferData: Data) -> UUID? {
        guard let transfer = try? JSONDecoder().decode(MirrorTabTransferData.self, from: transferData) else {
            return nil
        }
        return transfer.tab.id
    }

    /// Reads the drag id off any file-preview or bonsplit transfer type on
    /// `pasteboard`, trying data then string encodings, or `nil`.
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

    /// Discards the drag registered for `pasteboard` (if any) and sweeps every
    /// expired registry entry.
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
                icon: FilePreviewKindResolver().initialTabIconName(for: URL(fileURLWithPath: filePath)),
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

    /// The pasteboard types this writer can vend for `pasteboard`.
    public func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        let data = transferDataForDrag()
        mirrorTransferDataToDragPasteboard(data)
        return [
            Self.filePreviewTransferType,
            Self.bonsplitTransferType,
            .fileURL
        ]
    }

    /// The pasteboard payload for `type`: the tab-transfer JSON for the
    /// file-preview/bonsplit types, the standardized file URL string for
    /// `.fileURL`, or `nil`.
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
