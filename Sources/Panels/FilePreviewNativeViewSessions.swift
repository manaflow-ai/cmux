import Foundation

@MainActor
final class FilePreviewNativeViewSessions {
    let pdf = FilePreviewPDFSession()
    let image = FilePreviewImageSession()
    let media = FilePreviewMediaSession()
    let quickLook = FilePreviewQuickLookSession()

    deinit {
        // AppKit teardown is performed explicitly by closeAll() on the main actor.
    }

    func closeInactive(except mode: FilePreviewMode) {
        switch mode {
        case .text:
            closeAll()
        case .pdf:
            image.close()
            media.close()
            quickLook.close()
        case .image:
            pdf.close()
            media.close()
            quickLook.close()
        case .media:
            pdf.close()
            image.close()
            quickLook.close()
        case .quickLook:
            pdf.close()
            image.close()
            media.close()
        }
    }

    func closeAll() {
        pdf.close()
        image.close()
        media.close()
        quickLook.close()
    }
}
