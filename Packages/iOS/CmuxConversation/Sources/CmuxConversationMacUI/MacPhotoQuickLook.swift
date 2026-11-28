#if os(macOS)
import AppKit
import CmuxConversationCore
import Quartz

/// Double-clicking a photo opens it in Quick Look, zooming out of its bubble
/// and back, as Messages for macOS does.
@MainActor
final class MacPhotoQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = MacPhotoQuickLook()

    private var fileURL: URL?
    private weak var sourceView: NSView?
    private var sourceRect: CGRect = .zero

    func show(_ attachment: ConversationAttachment, image: NSImage, from view: NSView, rect: CGRect) {
        guard let url = Self.write(attachment, image: image) else { return }
        fileURL = url
        sourceView = view
        sourceRect = rect
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Quick Look previews files; the photo is written once per attachment to
    /// a private temporary folder (original bytes when the photo is local).
    private static func write(_ attachment: ConversationAttachment, image: NSImage) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-conversation-photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeID = attachment.id.replacingOccurrences(of: "/", with: "_")
        if let data = attachment.localData, let ext = attachment.url?.pathExtension, !ext.isEmpty {
            let url = folder.appendingPathComponent("\(safeID).\(ext)")
            if (try? data.write(to: url)) != nil { return url }
        }
        let url = folder.appendingPathComponent("\(safeID).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
              (try? png.write(to: url)) != nil else { return nil }
        return url
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { fileURL == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { fileURL as NSURL? }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        MainActor.assumeIsolated {
            guard let view = sourceView, let window = view.window else { return .zero }
            return window.convertToScreen(view.convert(sourceRect, to: nil))
        }
    }
}
#endif
