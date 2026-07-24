@MainActor
final class FilePreviewQuickLookViewCoordinator {
    var quickLook: FilePreviewQuickLookSession?

    init(panel: FilePreviewPanel) {
        quickLook = panel.nativeViewSessions.quickLook
    }
}
