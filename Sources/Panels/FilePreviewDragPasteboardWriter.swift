import AppKit
import AVKit
import Bonsplit
import Combine
import Foundation
import PDFKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers


// MARK: - Drag Pasteboard Writer
final class FilePreviewDragPasteboardWriter: NSObject, NSPasteboardWriting {
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

    static let bonsplitTransferType = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")

    private let filePath: String
    private let displayTitle: String
    private var transferData: Data?
    private var didMirrorTransferDataToDragPasteboard = false

    init(filePath: String, displayTitle: String) {
        self.filePath = filePath
        self.displayTitle = displayTitle
        super.init()
    }

    static func dragID(from transferData: Data) -> UUID? {
        guard let transfer = try? JSONDecoder().decode(MirrorTabTransferData.self, from: transferData) else {
            return nil
        }
        return transfer.tab.id
    }

    static func dragID(from pasteboard: NSPasteboard) -> UUID? {
        for type in [DragOverlayRoutingPolicy.filePreviewTransferType, Self.bonsplitTransferType] {
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

    static func discardRegisteredDrag(from pasteboard: NSPasteboard) {
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
                icon: FilePreviewKindResolver.initialTabIconName(for: URL(fileURLWithPath: filePath)),
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

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        let data = transferDataForDrag()
        mirrorTransferDataToDragPasteboard(data)
        return [
            DragOverlayRoutingPolicy.filePreviewTransferType,
            Self.bonsplitTransferType,
            .fileURL
        ]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == Self.bonsplitTransferType || type == DragOverlayRoutingPolicy.filePreviewTransferType {
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
            pasteboard.addTypes([DragOverlayRoutingPolicy.filePreviewTransferType, Self.bonsplitTransferType, .fileURL], owner: nil)
            pasteboard.setData(transferData, forType: Self.bonsplitTransferType)
            pasteboard.setData(transferData, forType: DragOverlayRoutingPolicy.filePreviewTransferType)
            pasteboard.setString(fileURLString, forType: .fileURL)
        }
        if Thread.isMainThread {
            write()
        } else {
            DispatchQueue.main.async(execute: write)
        }
    }
}

