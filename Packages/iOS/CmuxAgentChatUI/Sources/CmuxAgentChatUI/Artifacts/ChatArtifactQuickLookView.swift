#if os(iOS)
import QuickLook

/// Native Quick Look controller lifecycle for one local artifact file.
@MainActor
enum ChatArtifactQuickLookController {
    static func make(dataSource: ChatArtifactQuickLookCoordinator) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = dataSource
        return controller
    }

    static func update(
        _ controller: QLPreviewController,
        coordinator: ChatArtifactQuickLookCoordinator,
        fileURL: URL,
        title: String
    ) {
        coordinator.update(
            item: ChatArtifactQuickLookItem(fileURL: fileURL, title: title)
        )
        controller.reloadData()
    }
}
#endif
