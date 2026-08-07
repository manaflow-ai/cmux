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
    private var sharingServicePicker: NSSharingServicePicker?
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

    /// The item currently displayed by the live preview.
    var previewItem: (any QLPreviewItem)? {
        previewView?.previewItem
    }

    /// Updates the preview and the file URL used by its toolbar share action.
    func setPreviewItem(_ item: (any QLPreviewItem)?) {
        guard let item else {
            closeSharingServicePicker()
            previewView?.previewItem = nil
            return
        }
        guard let previewView = livePreviewView() else {
            closeSharingServicePicker()
            return
        }

        if previewView.previewItem !== item {
            closeSharingServicePicker()
        }
        previewView.previewItem = item
    }

    /// Clears the active item while preserving a reusable live preview.
    func clearPreviewItem() {
        setPreviewItem(nil)
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
        clearPreviewItem()
        // `shouldCloseWithWindow` transfers closure ownership to this host even
        // when the preview has never entered a window.
        previewView.close()
        previewView.removeFromSuperview()
        self.previewView = nil
    }

    /// Handles the standard responder-chain share action.
    @objc(share:)
    private func handleShare(_ sender: Any?) {
        showSharingServicePicker(from: sender)
    }

    /// Handles the action sent by Quick Look's embedded toolbar button.
    @objc(shareFromButton:)
    private func handleShareFromButton(_ sender: Any?) {
        showSharingServicePicker(from: sender)
    }

    private func showSharingServicePicker(from sender: Any?) {
        guard let previewView,
              let shareItemURL = previewView.previewItem?.previewItemURL,
              let previewWindow = previewView.window,
              previewWindow === window else { return }

        closeSharingServicePicker()
        let picker = NSSharingServicePicker(items: [shareItemURL])
        picker.delegate = self
        sharingServicePicker = picker

        let anchor = sharingAnchor(from: sender, in: previewView)
        // AppKit requires picker presentation during the originating mouse-down,
        // so keep Quick Look's responder action synchronous.
        picker.show(
            relativeTo: anchor.rect,
            of: anchor.view,
            preferredEdge: .maxY
        )
    }

    private func sharingAnchor(
        from sender: Any?,
        in previewView: NSView
    ) -> (rect: NSRect, view: NSView) {
        if let senderView = sender as? NSView,
           senderView !== previewView,
           senderView.window === previewView.window {
            return (senderView.bounds, senderView)
        }
        if let event = NSApp.currentEvent,
           event.type == .leftMouseDown,
           event.window === previewView.window {
            let point = previewView.convert(event.locationInWindow, from: nil)
            return (NSRect(origin: point, size: .zero), previewView)
        }
        let fallbackPoint = NSPoint(
            x: previewView.bounds.maxX,
            y: previewView.bounds.minY
        )
        return (NSRect(origin: fallbackPoint, size: .zero), previewView)
    }

    private func closeSharingServicePicker() {
        guard let sharingServicePicker else { return }
        self.sharingServicePicker = nil
        sharingServicePicker.delegate = nil
        sharingServicePicker.close()
    }
}

extension FilePreviewQuickLookContainerView: NSSharingServicePickerDelegate {
    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        guard sharingServicePicker === self.sharingServicePicker else { return }
        self.sharingServicePicker = nil
    }
}
