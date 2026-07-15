#if os(iOS)
import CmuxAgentChat
import Foundation

/// Immutable row snapshot shared by in-view and session gallery layouts.
struct TerminalArtifactGalleryDisplayItem: Identifiable, Equatable {
    let path: String
    let kind: ChatArtifactKind
    let displayName: String
    let size: Int64?
    let modifiedAt: Date?
    let exists: Bool
    let subtitle: String?

    var id: String { path }

    init(reference: TerminalArtifactReference) {
        path = reference.path
        kind = reference.kind
        displayName = reference.displayName
        size = reference.size
        modifiedAt = reference.modifiedAt
        exists = true
        subtitle = nil
    }

    init(galleryItem: ChatArtifactGalleryItem, subtitle: String? = nil) {
        path = galleryItem.path
        kind = galleryItem.kind
        displayName = galleryItem.displayName
        size = galleryItem.size
        modifiedAt = galleryItem.modifiedAt
        exists = galleryItem.exists
        self.subtitle = subtitle
    }
}
#endif
