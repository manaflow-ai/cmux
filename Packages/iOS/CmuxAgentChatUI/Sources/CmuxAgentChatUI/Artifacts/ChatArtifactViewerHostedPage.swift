#if os(iOS)
import QuickLook
import SwiftUI

/// Gives one path one stable SwiftUI hosting root inside the UIKit pager.
struct ChatArtifactViewerHostedPage: View {
    let model: ChatArtifactViewerPageModel
    let scope: ChatArtifactViewerScope
    let loader: ChatArtifactLoader
    let onImageMinimumZoomChanged: (String, Bool) -> Void
    let onDone: () -> Void

    var path: String { model.path }

    var body: some View {
        let snapshot = model.snapshot
        ChatArtifactViewerRouteView(
            snapshot: snapshot,
            scope: scope,
            actions: model.actions(
                loader: loader,
                quickLookCanPreview: { fileURL in
                    QLPreviewController.canPreview(ChatArtifactQuickLookItem(
                        fileURL: fileURL,
                        title: snapshot.displayName
                    ))
                }
            ),
            onImageMinimumZoomChanged: {
                onImageMinimumZoomChanged(snapshot.path, $0)
            },
            onDone: onDone
        )
        .clipped()
    }
}
#endif
