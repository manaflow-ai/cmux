import AppKit
import CmuxWorkspaces
import Foundation
import ObjectiveC
import Quartz

@MainActor
final class WorkspaceChecklistAttachmentQuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var items: [WorkspaceChecklistAttachmentQuickLookItem] = []

    func present(
        attachments: [WorkspaceChecklistAttachment],
        selectedAttachmentId: UUID?
    ) {
        let availableAttachments = attachments.filter { attachment in
            FileManager.default.fileExists(atPath: attachment.filePath)
        }
        guard !availableAttachments.isEmpty else {
            NSSound.beep()
            return
        }

        items = availableAttachments.map {
            WorkspaceChecklistAttachmentQuickLookItem(
                url: $0.fileURL,
                title: $0.displayName
            )
        }
        let selectedIndex = selectedAttachmentId.flatMap { selectedId in
            availableAttachments.firstIndex { $0.id == selectedId }
        } ?? 0

        guard let panel = QLPreviewPanel.shared() else { return }
        objc_setAssociatedObject(
            panel as Any,
            &workspaceChecklistAttachmentQuickLookControllerAssociationKey,
            self,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = selectedIndex
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            items.count
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            guard items.indices.contains(index) else { return nil }
            return items[index]
        }
    }

    nonisolated func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        guard let panel else { return }
        objc_setAssociatedObject(
            panel,
            &workspaceChecklistAttachmentQuickLookControllerAssociationKey,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

private var workspaceChecklistAttachmentQuickLookControllerAssociationKey: UInt8 = 0

private final class WorkspaceChecklistAttachmentQuickLookItem: NSObject, QLPreviewItem {
    private let url: URL
    private let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    var previewItemURL: URL? {
        url
    }

    var previewItemTitle: String? {
        title
    }
}
