/// Selects file actions without coupling visibility rules to SwiftUI rendering.
struct ChatArtifactActionVisibilityPolicy: Equatable {
    let actions: [ChatArtifactAction]
    let inlineStateIdentity: String?

    /// Creates the strict action set for an embedded content preview.
    init(inlineState state: ChatArtifactViewerState) {
        switch state {
        case .image:
            actions = [.share, .save, .copyImage]
            inlineStateIdentity = "image"
        case .pdf:
            actions = [.share, .save]
            inlineStateIdentity = "pdf"
        case .media:
            actions = [.share, .save]
            inlineStateIdentity = "media"
        case .quickLook:
            actions = [.share, .save]
            inlineStateIdentity = "quick-look"
        case .loading, .folder, .text, .markdown, .binary, .tooLarge,
             .unsupportedMedia, .fileMissing, .macUnreachable, .forbidden:
            actions = []
            inlineStateIdentity = nil
        }
    }

    /// Preserves the full viewer's existing file-action visibility.
    init(viewerHasFileActions: Bool, isTextFile: Bool) {
        inlineStateIdentity = nil
        guard viewerHasFileActions else {
            actions = []
            return
        }
        actions = isTextFile
            ? [.share, .save, .copyContents, .copyPath]
            : [.share, .save, .copyPath]
    }
}
