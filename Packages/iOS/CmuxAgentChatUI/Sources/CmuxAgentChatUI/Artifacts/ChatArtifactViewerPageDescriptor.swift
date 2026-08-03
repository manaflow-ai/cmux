#if os(iOS)
import QuickLook

/// Immutable dependencies for one path-stable native artifact page controller.
@MainActor
struct ChatArtifactViewerPageDescriptor {
    let model: ChatArtifactViewerPageModel
    let scope: ChatArtifactViewerScope
    let loader: ChatArtifactLoader
    let onImageMinimumZoomChanged: (String, Bool) -> Void
    let onImageAction: @MainActor (ChatArtifactAction, ChatArtifactViewerPageSnapshot) -> Void
    let onDone: () -> Void

    var path: String { model.path }

    func actions() -> ChatArtifactViewerPageActions {
        model.actions(
            loader: loader,
            quickLookCanPreview: { fileURL in
                QLPreviewController.canPreview(ChatArtifactQuickLookItem(
                    fileURL: fileURL,
                    title: model.snapshot.displayName
                ))
            }
        )
    }
}
#endif
