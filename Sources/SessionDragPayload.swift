import AppKit
import Foundation

/// Encodes a Vault capability in the pane-transfer format shared by all pane targets.
struct SessionDragPayload {
    private struct MirrorTabItem: Codable {
        let id: UUID
        let title: String
        let hasCustomTitle: Bool
        let icon: String?
        let iconImageData: Data?
        let iconAsset: String?
        let kind: String?
        let isDirty: Bool
        let showsNotificationBadge: Bool
        let isLoading: Bool
        let isAudioMuted: Bool
        let isAudioPlaying: Bool
        let isPinned: Bool
        let showsRemoteIndicator: Bool
    }

    private struct MirrorTabTransferData: Codable {
        let tab: MirrorTabItem
        let sourcePaneId: UUID
        let sourceProcessId: Int32
    }

    static func pasteboardItem(for entry: SessionEntry, dragID: UUID) -> NSPasteboardItem? {
        let transfer = MirrorTabTransferData(
            tab: MirrorTabItem(
                id: dragID,
                title: entry.displayTitle,
                hasCustomTitle: false,
                icon: "terminal.fill",
                iconImageData: nil,
                iconAsset: nil,
                kind: "terminal",
                isDirty: false,
                showsNotificationBadge: false,
                isLoading: false,
                isAudioMuted: false,
                isAudioPlaying: false,
                isPinned: false,
                showsRemoteIndicator: false
            ),
            sourcePaneId: UUID(),
            sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier)
        )
        guard let data = try? JSONEncoder().encode(transfer) else { return nil }
        let item = NSPasteboardItem()
        guard item.setData(data, forType: DragOverlayRoutingPolicy.bonsplitTabTransferType) else {
            return nil
        }
        return item
    }
}
