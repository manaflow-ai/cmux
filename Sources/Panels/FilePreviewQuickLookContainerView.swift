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
    private var isRetiring = false
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
        guard !isRetiring, !isDismantled else { return nil }
        if let previewView {
            return previewView
        }

        guard let previewView = QLPreviewView(frame: bounds, style: .normal) else {
            return nil
        }
        previewView.autostarts = true
        previewView.shouldCloseWithWindow = false
        previewView.autoresizingMask = [.width, .height]
        self.previewView = previewView
        // Register the child before AppKit can synchronously re-enter this host.
        addSubview(previewView)
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
        guard !isRetiring, let previewView else { return }
        isRetiring = true
        self.previewView = nil
        defer { isRetiring = false }

        // Invalidate the slot before any AppKit call. `close()` and
        // `removeFromSuperview()` can synchronously trigger SwiftUI/responder
        // updates while the old Quick Look view is already deactivated.
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
    }
}
