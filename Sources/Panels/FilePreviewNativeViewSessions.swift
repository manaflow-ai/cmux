import Foundation

@MainActor
final class FilePreviewNativeViewSessions {
    let pdf = FilePreviewPDFSession()
    let image = FilePreviewImageSession()
    let media = FilePreviewMediaSession()
    let quickLook = FilePreviewQuickLookSession()
    /// Code editor webview (text mode with `fileEditor.engine = "code"`).
    let codeEditorWeb = CodeEditorWebSession()

    deinit {
        // AppKit teardown is performed explicitly by closeAll() on the main actor.
    }

    func closeInactive(except mode: FilePreviewMode) {
        switch mode {
        case .text:
            pdf.close()
            image.close()
            media.close()
            quickLook.close()
        case .pdf:
            image.close()
            media.close()
            quickLook.close()
            codeEditorWeb.close()
        case .image:
            pdf.close()
            media.close()
            quickLook.close()
            codeEditorWeb.close()
        case .media:
            pdf.close()
            image.close()
            quickLook.close()
            codeEditorWeb.close()
        case .quickLook:
            pdf.close()
            image.close()
            media.close()
            codeEditorWeb.close()
        }
    }

    func closeAll() {
        pdf.close()
        image.close()
        media.close()
        quickLook.close()
        codeEditorWeb.close()
    }
}
