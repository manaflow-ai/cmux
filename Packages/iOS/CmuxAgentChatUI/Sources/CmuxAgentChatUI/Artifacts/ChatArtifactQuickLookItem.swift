#if os(iOS)
import Foundation
import QuickLook

/// Supplies a local artifact URL and original display name to Quick Look.
final class ChatArtifactQuickLookItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(fileURL: URL, title: String?) {
        previewItemURL = fileURL
        previewItemTitle = title
    }
}
#endif
