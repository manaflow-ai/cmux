/// Selects file actions without coupling visibility rules to SwiftUI rendering.
struct ChatArtifactActionVisibilityPolicy: Equatable {
    let actions: [ChatArtifactAction]

    /// Creates the strict action set for an embedded content preview.
    init(inlineState state: ChatArtifactViewerState) {
        switch state {
        case .image:
            actions = [.share, .save, .copyImage]
        case .pdf, .media, .quickLook:
            actions = [.share, .save]
        case .loading, .folder, .text, .markdown, .binary, .tooLarge,
             .unsupportedMedia, .fileMissing, .macUnreachable, .forbidden:
            actions = []
        }
    }

    /// Preserves the full viewer's existing file-action visibility.
    init(viewerHasFileActions: Bool, isTextFile: Bool) {
        guard viewerHasFileActions else {
            actions = []
            return
        }
        actions = isTextFile
            ? [.share, .save, .copyContents, .copyPath]
            : [.share, .save, .copyPath]
    }
}
