import AppKit
import Quartz

/// Stable host that owns the full lifecycle of one replaceable Quick Look view.
///
/// Quick Look closes a preview automatically when its window closes unless the
/// application opts into explicit ownership. This host disables that implicit
/// close and retires the preview before a real window detachment or final
/// representable teardown, so no closed preview is reused.
final class FilePreviewQuickLookContainerView: NSView {
    private var previewView: QLPreviewView?
    private var isDismantled = false

    /// Creates an empty stable host for a replaceable inner preview.
    static func make() -> FilePreviewQuickLookContainerView {
        FilePreviewQuickLookContainerView(frame: .zero)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let currentWindow = window, currentWindow !== newWindow {
            retireLivePreview(reason: "window-transition")
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Returns the preview owned by this mounted host, creating it when needed.
    /// A dismantled representable cannot create or re-adopt a preview.
    func livePreviewView() -> QLPreviewView? {
        if let previewView {
            return previewView
        }
        guard !isDismantled else { return nil }

        guard let previewView = QLPreviewView(frame: bounds, style: .normal) else {
            return nil
        }
        previewView.autostarts = true
        previewView.shouldCloseWithWindow = false
        previewView.autoresizingMask = [.width, .height]
        addSubview(previewView)
        self.previewView = previewView
        return previewView
    }

    /// Clears the active item while preserving a reusable live preview.
    func clearPreviewItem() {
        previewView?.previewItem = nil
    }

    /// Permanently tears down this representable's Quick Look ownership.
    func dismantle() {
        guard !isDismantled else { return }
        isDismantled = true
        retireLivePreview(reason: "representable-dismantle")
        removeFromSuperview()
    }

    private func retireLivePreview(reason: String) {
        guard let previewView else { return }
        sentryBreadcrumb(
            "quickLook.preview.retire",
            category: "filePreview",
            data: ["reason": reason]
        )
        previewView.previewItem = nil
        // `shouldCloseWithWindow` transfers closure ownership to this host even
        // when the preview has never entered a window.
        previewView.close()
        previewView.removeFromSuperview()
        self.previewView = nil
    }
}
